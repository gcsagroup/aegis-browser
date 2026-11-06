-- SOURCE ONLY until a separately admitted, owned PostgreSQL fixture executes it.
CREATE SCHEMA provider_b1 AUTHORIZATION b1_migrator;
CREATE DOMAIN provider_b1.label AS text CHECK (length(VALUE) BETWEEN 1 AND 128);
CREATE DOMAIN provider_b1.authority_label AS text CHECK (length(VALUE) BETWEEN 1 AND 256);
CREATE DOMAIN provider_b1.digest AS bytea CHECK (octet_length(VALUE) = 32);
CREATE DOMAIN provider_b1.tick AS bigint CHECK (VALUE BETWEEN 0 AND 9007199254740991);
CREATE TABLE provider_b1.domains (
  issuer provider_b1.authority_label NOT NULL, realm provider_b1.label NOT NULL,
  service_environment provider_b1.label NOT NULL, audience provider_b1.authority_label NOT NULL,
  trust_epoch provider_b1.tick NOT NULL CHECK (trust_epoch > 0),
  time_highwater provider_b1.tick NOT NULL, revocation_seq provider_b1.tick NOT NULL,
  PRIMARY KEY (issuer,realm,service_environment)
);
-- Logged, independently committed clock state. Business transactions never
-- read or lock this row. A pending observation survives cancellation/restart.
CREATE TABLE provider_b1.domain_clocks (
  issuer provider_b1.authority_label NOT NULL, realm provider_b1.label NOT NULL,
  service_environment provider_b1.label NOT NULL, audience provider_b1.authority_label NOT NULL,
  trust_epoch provider_b1.tick NOT NULL CHECK (trust_epoch > 0),
  highwater provider_b1.tick NOT NULL, pending_id uuid,
  lock_id integer GENERATED ALWAYS AS IDENTITY (MINVALUE 1 MAXVALUE 2147483647 NO CYCLE) UNIQUE NOT NULL CHECK (lock_id>0),
  PRIMARY KEY (issuer,realm,service_environment),
  FOREIGN KEY (issuer,realm,service_environment) REFERENCES provider_b1.domains ON DELETE RESTRICT
);
CREATE FUNCTION provider_b1.seed_clock() RETURNS trigger LANGUAGE plpgsql
SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  INSERT INTO provider_b1.domain_clocks (issuer,realm,service_environment,audience,trust_epoch,highwater,pending_id) VALUES
    (NEW.issuer,NEW.realm,NEW.service_environment,NEW.audience,NEW.trust_epoch,NEW.time_highwater,NULL);
  RETURN NEW;
END $$;
CREATE TRIGGER seed_clock AFTER INSERT ON provider_b1.domains
  FOR EACH ROW EXECUTE FUNCTION provider_b1.seed_clock();
-- Namespace 1110520113 is reserved for B1 clock lifecycle in owned DB b1.
-- Two-int advisory identities are allocated, not hashed; no reuse or wrap.
CREATE FUNCTION provider_b1.clock_key(i text,r text,e text,a text,epoch bigint)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE c provider_b1.domain_clocks;
BEGIN
  SELECT * INTO c FROM provider_b1.domain_clocks WHERE issuer=i AND realm=r AND service_environment=e;
  IF NOT FOUND OR c.audience<>a OR c.trust_epoch<>epoch THEN RAISE EXCEPTION 'B1 clock binding'; END IF;
  RETURN c.lock_id;
END $$;
CREATE FUNCTION provider_b1.clock_owned(k integer)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_locks
    WHERE locktype='advisory' AND database=(SELECT oid FROM pg_catalog.pg_database WHERE datname=pg_catalog.current_database())
      AND pid=pg_catalog.pg_backend_pid() AND classid=1110520113::oid AND (k IS NULL OR objid=k::oid)
      AND objsubid=2 AND mode='ExclusiveLock' AND granted)
$$;
CREATE FUNCTION provider_b1.clock_assert_owned(i text,r text,e text,a text,epoch bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF NOT provider_b1.clock_owned(provider_b1.clock_key(i,r,e,a,epoch)) THEN RAISE EXCEPTION 'B1 clock ownership'; END IF;
END $$;
CREATE FUNCTION provider_b1.clock_try_lock(i text,r text,e text,a text,epoch bigint)
RETURNS TABLE(acquired boolean) LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE k integer;
BEGIN
  k:=provider_b1.clock_key(i,r,e,a,epoch);
  IF provider_b1.clock_owned(NULL::integer) THEN RAISE EXCEPTION 'B1 recursive clock ownership'; END IF;
  RETURN QUERY SELECT pg_catalog.pg_try_advisory_lock(1110520113,k);
END $$;
CREATE FUNCTION provider_b1.clock_unlock(i text,r text,e text,a text,epoch bigint)
RETURNS TABLE(released boolean) LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE k integer; unlocked boolean;
BEGIN
  k:=provider_b1.clock_key(i,r,e,a,epoch);
  PERFORM provider_b1.clock_assert_owned(i,r,e,a,epoch);
  unlocked:=pg_catalog.pg_advisory_unlock(1110520113,k);
  RETURN QUERY SELECT unlocked AND NOT provider_b1.clock_owned(NULL::integer);
END $$;
CREATE FUNCTION provider_b1.clock_begin(i text,r text,e text,a text,epoch bigint,marker uuid)
RETURNS TABLE(ready boolean) LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE c provider_b1.domain_clocks;
BEGIN
  PERFORM provider_b1.clock_assert_owned(i,r,e,a,epoch);
  SELECT * INTO c FROM provider_b1.domain_clocks
    WHERE issuer=i AND realm=r AND service_environment=e FOR UPDATE;
  IF NOT FOUND OR c.audience<>a OR c.trust_epoch<>epoch OR c.pending_id IS NOT NULL OR marker IS NULL THEN
    RETURN QUERY SELECT false; RETURN;
  END IF;
  UPDATE provider_b1.domain_clocks SET pending_id=marker WHERE issuer=i AND realm=r AND service_environment=e;
  RETURN QUERY SELECT true;
END $$;
CREATE FUNCTION provider_b1.clock_finish(i text,r text,e text,a text,epoch bigint,marker uuid,upper_bound bigint)
RETURNS TABLE(completed boolean,highwater bigint,db_now bigint,rollback_detected boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE c provider_b1.domain_clocks; sampled bigint; next_h bigint;
BEGIN
  PERFORM provider_b1.clock_assert_owned(i,r,e,a,epoch);
  SELECT * INTO c FROM provider_b1.domain_clocks
    WHERE issuer=i AND realm=r AND service_environment=e FOR UPDATE;
  IF NOT FOUND OR c.audience<>a OR c.trust_epoch<>epoch OR c.pending_id IS DISTINCT FROM marker OR
    marker IS NULL OR upper_bound IS NULL OR upper_bound<0 OR upper_bound>9007199254740991 THEN
    RETURN QUERY SELECT false,NULL::bigint,NULL::bigint,false; RETURN;
  END IF;
  sampled:=floor(extract(epoch from pg_catalog.clock_timestamp()))::bigint;
  next_h:=greatest(c.highwater,upper_bound,sampled);
  UPDATE provider_b1.domain_clocks SET highwater=next_h,pending_id=NULL
    WHERE issuer=i AND realm=r AND service_environment=e;
  -- Rollback is returned AFTER the monotonic observation is saved, not raised
  -- inside the transaction that would undo it.
  RETURN QUERY SELECT true,next_h,sampled,upper_bound<c.highwater;
END $$;
CREATE TABLE provider_b1.installations (
  issuer provider_b1.authority_label NOT NULL, realm provider_b1.label NOT NULL,
  service_environment provider_b1.label NOT NULL, id uuid NOT NULL,
  channel text NOT NULL CHECK (length(channel) BETWEEN 1 AND 32), key_id provider_b1.label NOT NULL,
  key_hash provider_b1.digest NOT NULL, public_jwk jsonb NOT NULL,
  registration_digest provider_b1.digest NOT NULL,
  PRIMARY KEY (issuer,realm,service_environment,id),
  UNIQUE (issuer,realm,service_environment,channel,key_hash),
  FOREIGN KEY (issuer,realm,service_environment) REFERENCES provider_b1.domains ON DELETE RESTRICT,
  CHECK (jsonb_typeof(public_jwk) = 'object')
);
CREATE TABLE provider_b1.pools (
  issuer provider_b1.authority_label NOT NULL, realm provider_b1.label NOT NULL,
  service_environment provider_b1.label NOT NULL, id uuid NOT NULL, installation_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind = 'installation_guest'),
  PRIMARY KEY (issuer,realm,service_environment,id),
  UNIQUE (issuer,realm,service_environment,installation_id),
  UNIQUE (issuer,realm,service_environment,id,installation_id),
  FOREIGN KEY (issuer,realm,service_environment,installation_id)
    REFERENCES provider_b1.installations ON DELETE RESTRICT
);
CREATE TABLE provider_b1.profiles (
  issuer provider_b1.authority_label NOT NULL, realm provider_b1.label NOT NULL,
  service_environment provider_b1.label NOT NULL, id uuid NOT NULL,
  installation_id uuid NOT NULL, pool_id uuid NOT NULL, ownership_hash provider_b1.digest NOT NULL,
  profile_binding uuid NOT NULL, key_id provider_b1.label NOT NULL,
  key_hash provider_b1.digest NOT NULL, public_jwk jsonb NOT NULL,
  PRIMARY KEY (issuer,realm,service_environment,id),
  UNIQUE (issuer,realm,service_environment,installation_id,ownership_hash),
  UNIQUE (issuer,realm,service_environment,profile_binding),
  UNIQUE (issuer,realm,service_environment,key_hash),
  UNIQUE (issuer,realm,service_environment,id,installation_id,pool_id),
  FOREIGN KEY (issuer,realm,service_environment,pool_id,installation_id)
    REFERENCES provider_b1.pools (issuer,realm,service_environment,id,installation_id) ON DELETE RESTRICT,
  CHECK (jsonb_typeof(public_jwk) = 'object')
);
CREATE TABLE provider_b1.credentials (
  issuer provider_b1.authority_label NOT NULL, realm provider_b1.label NOT NULL,
  service_environment provider_b1.label NOT NULL, id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('installation-credential','profile-credential')),
  installation_id uuid NOT NULL, pool_id uuid NOT NULL, profile_id uuid, parent_id uuid,
  revision provider_b1.tick NOT NULL CHECK (revision > 0), claims jsonb NOT NULL,
  claims_hash provider_b1.digest NOT NULL, immutable_hash provider_b1.digest NOT NULL,
  issued_at provider_b1.tick NOT NULL, not_before provider_b1.tick NOT NULL,
  expires_at provider_b1.tick NOT NULL, revoked_at provider_b1.tick,
  jws text NOT NULL CHECK (octet_length(jws) BETWEEN 1 AND 131072),
  PRIMARY KEY (issuer,realm,service_environment,id),
  UNIQUE (issuer,realm,service_environment,id,installation_id,pool_id),
  FOREIGN KEY (issuer,realm,service_environment,pool_id,installation_id)
    REFERENCES provider_b1.pools (issuer,realm,service_environment,id,installation_id) ON DELETE RESTRICT,
  FOREIGN KEY (issuer,realm,service_environment,profile_id,installation_id,pool_id)
    REFERENCES provider_b1.profiles (issuer,realm,service_environment,id,installation_id,pool_id) ON DELETE RESTRICT,
  FOREIGN KEY (issuer,realm,service_environment,parent_id,installation_id,pool_id)
    REFERENCES provider_b1.credentials (issuer,realm,service_environment,id,installation_id,pool_id) ON DELETE RESTRICT,
  CHECK ((kind='installation-credential' AND profile_id IS NULL AND parent_id IS NULL) OR
    (kind='profile-credential' AND profile_id IS NOT NULL AND parent_id IS NOT NULL)),
  CHECK (issued_at <= not_before AND not_before < expires_at),
  CHECK (jsonb_typeof(claims) = 'object')
);
CREATE UNIQUE INDEX one_root ON provider_b1.credentials (issuer,realm,service_environment,installation_id)
  WHERE kind='installation-credential';
CREATE UNIQUE INDEX one_profile_credential ON provider_b1.credentials (issuer,realm,service_environment,profile_id)
  WHERE kind='profile-credential';
CREATE TABLE provider_b1.operations (
  issuer provider_b1.authority_label NOT NULL, realm provider_b1.label NOT NULL,
  service_environment provider_b1.label NOT NULL, id uuid NOT NULL, actor provider_b1.label NOT NULL,
  operation text NOT NULL CHECK (operation IN ('register','profile-issue','revoke')),
  idem_key provider_b1.label NOT NULL, request_hash provider_b1.digest NOT NULL,
  result_credential_id uuid, status smallint NOT NULL CHECK (status BETWEEN 200 AND 599),
  headers jsonb NOT NULL CHECK (jsonb_typeof(headers)='object'), body bytea NOT NULL,
  result_deadline provider_b1.tick, created_at provider_b1.tick NOT NULL,
  PRIMARY KEY (issuer,realm,service_environment,id),
  UNIQUE (issuer,realm,service_environment,actor,operation,idem_key),
  FOREIGN KEY (issuer,realm,service_environment) REFERENCES provider_b1.domains ON DELETE RESTRICT,
  FOREIGN KEY (issuer,realm,service_environment,result_credential_id)
    REFERENCES provider_b1.credentials ON DELETE RESTRICT,
  CHECK (octet_length(body) <= 131072),
  CHECK ((operation='revoke' AND result_credential_id IS NULL AND result_deadline IS NULL) OR
    (operation<>'revoke' AND result_credential_id IS NOT NULL AND result_deadline IS NOT NULL))
);
CREATE TABLE provider_b1.challenges (
  issuer provider_b1.authority_label NOT NULL, realm provider_b1.label NOT NULL,
  service_environment provider_b1.label NOT NULL, id uuid NOT NULL, nonce_hash provider_b1.digest NOT NULL,
  operation text NOT NULL CHECK (operation IN ('register','profile-issue')), actor provider_b1.label NOT NULL,
  key_hash provider_b1.digest NOT NULL, recipient_hash provider_b1.digest,
  signer_jwk jsonb NOT NULL CHECK (jsonb_typeof(signer_jwk)='object'), recipient_jwk jsonb,
  parent_id uuid, parent_revision provider_b1.tick, idem_key provider_b1.label NOT NULL,
  request_hash provider_b1.digest NOT NULL, issued_at provider_b1.tick NOT NULL,
  expires_at provider_b1.tick NOT NULL, consumed_operation_id uuid, consumed_at provider_b1.tick,
  PRIMARY KEY (issuer,realm,service_environment,id),
  UNIQUE (issuer,realm,service_environment,nonce_hash),
  FOREIGN KEY (issuer,realm,service_environment) REFERENCES provider_b1.domains ON DELETE RESTRICT,
  FOREIGN KEY (issuer,realm,service_environment,parent_id) REFERENCES provider_b1.credentials ON DELETE RESTRICT,
  FOREIGN KEY (issuer,realm,service_environment,consumed_operation_id) REFERENCES provider_b1.operations ON DELETE RESTRICT,
  CHECK (issued_at < expires_at),
  CHECK ((operation='register' AND parent_id IS NULL AND parent_revision IS NULL AND
    recipient_hash IS NULL AND recipient_jwk IS NULL) OR
    (operation='profile-issue' AND parent_id IS NOT NULL AND parent_revision > 0 AND
      recipient_hash IS NOT NULL AND recipient_jwk IS NOT NULL AND jsonb_typeof(recipient_jwk)='object')),
  CHECK ((consumed_operation_id IS NULL AND consumed_at IS NULL) OR
    (consumed_operation_id IS NOT NULL AND consumed_at IS NOT NULL AND consumed_at >= issued_at AND consumed_at < expires_at))
);

-- B1 is append-only except monotonic domain observations, terminal revocation,
-- and a single challenge-consumption transition. No rotation/revision writer.
CREATE FUNCTION provider_b1.protect() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'B1 tombstone retention required'; END IF;
  IF TG_TABLE_NAME='domains' THEN
    IF (NEW.issuer,NEW.realm,NEW.service_environment,NEW.audience) IS DISTINCT FROM
       (OLD.issuer,OLD.realm,OLD.service_environment,OLD.audience) OR
       NEW.trust_epoch IS DISTINCT FROM OLD.trust_epoch OR NEW.time_highwater IS DISTINCT FROM OLD.time_highwater OR
       NEW.revocation_seq < OLD.revocation_seq THEN RAISE EXCEPTION 'B1 monotonic domain required'; END IF;
  ELSIF TG_TABLE_NAME='domain_clocks' THEN
    IF (NEW.issuer,NEW.realm,NEW.service_environment,NEW.audience,NEW.trust_epoch,NEW.lock_id) IS DISTINCT FROM
      (OLD.issuer,OLD.realm,OLD.service_environment,OLD.audience,OLD.trust_epoch,OLD.lock_id) OR NEW.highwater<OLD.highwater OR
      (OLD.pending_id IS NULL AND (NEW.pending_id IS NULL OR NEW.highwater<>OLD.highwater)) OR
      (OLD.pending_id IS NOT NULL AND NEW.pending_id IS NOT NULL) THEN
      RAISE EXCEPTION 'B1 clock transition invalid'; END IF;
  ELSIF TG_TABLE_NAME='credentials' THEN
    IF (to_jsonb(NEW)-'revoked_at') IS DISTINCT FROM (to_jsonb(OLD)-'revoked_at') OR
       (OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at) THEN
      RAISE EXCEPTION 'B1 credential immutable';
    END IF;
  ELSIF TG_TABLE_NAME='challenges' THEN
    IF (to_jsonb(NEW)-ARRAY['consumed_operation_id','consumed_at']) IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['consumed_operation_id','consumed_at']) OR
       (OLD.consumed_operation_id IS NOT NULL AND NEW IS DISTINCT FROM OLD) THEN
      RAISE EXCEPTION 'B1 challenge immutable';
    END IF;
  ELSE
    IF NEW IS DISTINCT FROM OLD THEN RAISE EXCEPTION 'B1 row immutable'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER protect_domains BEFORE UPDATE OR DELETE ON provider_b1.domains FOR EACH ROW EXECUTE FUNCTION provider_b1.protect();
CREATE TRIGGER protect_clocks BEFORE UPDATE OR DELETE ON provider_b1.domain_clocks FOR EACH ROW EXECUTE FUNCTION provider_b1.protect();
CREATE TRIGGER protect_installations BEFORE UPDATE OR DELETE ON provider_b1.installations FOR EACH ROW EXECUTE FUNCTION provider_b1.protect();
CREATE TRIGGER protect_pools BEFORE UPDATE OR DELETE ON provider_b1.pools FOR EACH ROW EXECUTE FUNCTION provider_b1.protect();
CREATE TRIGGER protect_profiles BEFORE UPDATE OR DELETE ON provider_b1.profiles FOR EACH ROW EXECUTE FUNCTION provider_b1.protect();
CREATE TRIGGER protect_credentials BEFORE UPDATE OR DELETE ON provider_b1.credentials FOR EACH ROW EXECUTE FUNCTION provider_b1.protect();
CREATE TRIGGER protect_operations BEFORE UPDATE OR DELETE ON provider_b1.operations FOR EACH ROW EXECUTE FUNCTION provider_b1.protect();
CREATE TRIGGER protect_challenges BEFORE UPDATE OR DELETE ON provider_b1.challenges FOR EACH ROW EXECUTE FUNCTION provider_b1.protect();

CREATE FUNCTION provider_b1.capacity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n bigint; cap bigint;
BEGIN
  PERFORM 1 FROM provider_b1.domains WHERE issuer=NEW.issuer AND realm=NEW.realm AND
    service_environment=NEW.service_environment FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'B1 domain required'; END IF;
  CASE TG_TABLE_NAME
    WHEN 'installations' THEN
      SELECT count(*) INTO n FROM provider_b1.installations WHERE issuer=NEW.issuer AND realm=NEW.realm AND service_environment=NEW.service_environment;
      cap := 128;
    WHEN 'profiles' THEN
      SELECT count(*) INTO n FROM provider_b1.profiles WHERE issuer=NEW.issuer AND realm=NEW.realm AND service_environment=NEW.service_environment AND installation_id=NEW.installation_id;
      cap := 8;
    WHEN 'challenges' THEN
      SELECT count(*) INTO n FROM provider_b1.challenges WHERE issuer=NEW.issuer AND realm=NEW.realm AND service_environment=NEW.service_environment;
      cap := 4096;
    WHEN 'operations' THEN
      SELECT count(*) INTO n FROM provider_b1.operations WHERE issuer=NEW.issuer AND realm=NEW.realm AND service_environment=NEW.service_environment AND (operation='revoke')=(NEW.operation='revoke');
      cap := CASE WHEN NEW.operation='revoke' THEN 128 ELSE 4096 END;
    ELSE RAISE EXCEPTION 'B1 capacity table invalid';
  END CASE;
  IF n >= cap THEN RAISE EXCEPTION 'B1 state capacity'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cap_installations BEFORE INSERT ON provider_b1.installations FOR EACH ROW EXECUTE FUNCTION provider_b1.capacity();
CREATE TRIGGER cap_profiles BEFORE INSERT ON provider_b1.profiles FOR EACH ROW EXECUTE FUNCTION provider_b1.capacity();
CREATE TRIGGER cap_challenges BEFORE INSERT ON provider_b1.challenges FOR EACH ROW EXECUTE FUNCTION provider_b1.capacity();
CREATE TRIGGER cap_operations BEFORE INSERT ON provider_b1.operations FOR EACH ROW EXECUTE FUNCTION provider_b1.capacity();

CREATE FUNCTION provider_b1.bind_credential() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE i provider_b1.installations; p provider_b1.profiles; c provider_b1.credentials; d provider_b1.domains;
BEGIN
  SELECT * INTO STRICT d FROM provider_b1.domains WHERE issuer=NEW.issuer AND realm=NEW.realm AND service_environment=NEW.service_environment;
  SELECT * INTO STRICT i FROM provider_b1.installations WHERE issuer=NEW.issuer AND realm=NEW.realm AND service_environment=NEW.service_environment AND id=NEW.installation_id;
  IF NEW.claims->>'issuer' IS DISTINCT FROM NEW.issuer::text OR NEW.claims->>'audience' IS DISTINCT FROM d.audience::text OR
    NEW.claims->>'realm' IS DISTINCT FROM NEW.realm::text OR NEW.claims->>'serviceEnvironment' IS DISTINCT FROM NEW.service_environment::text OR
    NEW.claims->>'kind' IS DISTINCT FROM NEW.kind OR NEW.claims->>'credentialId' IS DISTINCT FROM NEW.id::text OR
    NEW.claims->>'installationRef' IS DISTINCT FROM NEW.installation_id::text OR NEW.claims->>'entitlementAccountId' IS DISTINCT FROM NEW.pool_id::text OR
    (NEW.claims->>'issuedAt')::bigint IS DISTINCT FROM NEW.issued_at OR (NEW.claims->>'notBefore')::bigint IS DISTINCT FROM NEW.not_before OR
    (NEW.claims->>'expiresAt')::bigint IS DISTINCT FROM NEW.expires_at THEN RAISE EXCEPTION 'B1 credential binding'; END IF;
  IF NEW.kind='installation-credential' THEN
    IF NEW.claims->>'installationKeyId' IS DISTINCT FROM i.key_id::text OR (NEW.claims->>'revision')::bigint IS DISTINCT FROM NEW.revision THEN
      RAISE EXCEPTION 'B1 root binding'; END IF;
  ELSE
    SELECT * INTO STRICT p FROM provider_b1.profiles WHERE issuer=NEW.issuer AND realm=NEW.realm AND service_environment=NEW.service_environment AND id=NEW.profile_id;
    SELECT * INTO STRICT c FROM provider_b1.credentials WHERE issuer=NEW.issuer AND realm=NEW.realm AND service_environment=NEW.service_environment AND id=NEW.parent_id;
    IF c.kind<>'installation-credential' OR c.revoked_at IS NOT NULL OR NEW.expires_at>c.expires_at OR NEW.not_before<c.not_before OR
      p.key_hash=i.key_hash OR NEW.claims->>'principalId' IS DISTINCT FROM p.id::text OR
      NEW.claims->>'recipientKeyId' IS DISTINCT FROM p.key_id::text OR NEW.claims->>'profileBinding' IS DISTINCT FROM p.profile_binding::text OR
      NEW.claims->>'parentCredentialId' IS DISTINCT FROM c.id::text OR (NEW.claims->>'credentialRevision')::bigint IS DISTINCT FROM NEW.revision OR
      NEW.claims->>'profileKind' IS DISTINCT FROM 'normal' OR NEW.claims->>'identityKind' IS DISTINCT FROM 'installation_guest' THEN
      RAISE EXCEPTION 'B1 profile binding'; END IF;
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER bind_credentials AFTER INSERT ON provider_b1.credentials
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION provider_b1.bind_credential();
CREATE FUNCTION provider_b1.bind_challenge() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE op provider_b1.operations; c provider_b1.credentials; i provider_b1.installations;
BEGIN
  IF NEW.parent_id IS NOT NULL THEN
    SELECT * INTO STRICT c FROM provider_b1.credentials WHERE issuer=NEW.issuer AND realm=NEW.realm AND service_environment=NEW.service_environment AND id=NEW.parent_id;
    SELECT * INTO STRICT i FROM provider_b1.installations WHERE issuer=NEW.issuer AND realm=NEW.realm AND service_environment=NEW.service_environment AND id=c.installation_id;
    IF c.kind<>'installation-credential' OR c.revision<>NEW.parent_revision OR NEW.actor<>i.id::text OR NEW.key_hash<>i.key_hash OR NEW.signer_jwk<>i.public_jwk THEN
      RAISE EXCEPTION 'B1 challenge parent binding'; END IF;
  END IF;
  IF NEW.consumed_operation_id IS NOT NULL THEN
    SELECT * INTO STRICT op FROM provider_b1.operations WHERE issuer=NEW.issuer AND realm=NEW.realm AND service_environment=NEW.service_environment AND id=NEW.consumed_operation_id;
    IF (op.actor,op.operation,op.idem_key,op.request_hash) IS DISTINCT FROM (NEW.actor,NEW.operation,NEW.idem_key,NEW.request_hash) THEN
      RAISE EXCEPTION 'B1 consumed operation binding'; END IF;
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER bind_challenges AFTER INSERT OR UPDATE ON provider_b1.challenges
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION provider_b1.bind_challenge();
CREATE FUNCTION provider_b1.bind_operation() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c provider_b1.credentials;
BEGIN
  IF NEW.result_credential_id IS NOT NULL THEN
    SELECT * INTO STRICT c FROM provider_b1.credentials WHERE issuer=NEW.issuer AND realm=NEW.realm AND service_environment=NEW.service_environment AND id=NEW.result_credential_id;
    IF NEW.result_deadline<>c.expires_at OR
      (NEW.operation='register' AND c.kind<>'installation-credential') OR
      (NEW.operation='profile-issue' AND (c.kind<>'profile-credential' OR NEW.actor<>c.installation_id::text)) THEN
      RAISE EXCEPTION 'B1 operation result binding'; END IF;
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER bind_operations AFTER INSERT ON provider_b1.operations
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION provider_b1.bind_operation();

-- Roles must have been provisioned by the admitted external fixture owner.
REVOKE ALL ON SCHEMA provider_b1 FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA provider_b1 FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA provider_b1 FROM PUBLIC;
GRANT USAGE ON SCHEMA provider_b1 TO b1_app;
GRANT USAGE ON DOMAIN provider_b1.label,provider_b1.authority_label,provider_b1.digest,provider_b1.tick TO b1_app;
GRANT SELECT ON ALL TABLES IN SCHEMA provider_b1 TO b1_app;
GRANT INSERT ON provider_b1.installations,provider_b1.pools,provider_b1.profiles,provider_b1.credentials,provider_b1.operations,provider_b1.challenges TO b1_app;
GRANT UPDATE (revocation_seq) ON provider_b1.domains TO b1_app;
GRANT UPDATE (id) ON provider_b1.installations,provider_b1.pools,provider_b1.profiles,provider_b1.operations TO b1_app;
GRANT UPDATE (revoked_at) ON provider_b1.credentials TO b1_app;
GRANT UPDATE (consumed_operation_id,consumed_at) ON provider_b1.challenges TO b1_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA provider_b1 TO b1_app;
REVOKE EXECUTE ON FUNCTION provider_b1.seed_clock(),provider_b1.clock_key(text,text,text,text,bigint),
  provider_b1.clock_owned(integer),provider_b1.clock_assert_owned(text,text,text,text,bigint) FROM b1_app;
-- Clock functions are the only app mutation path; no direct clock DML grants.
