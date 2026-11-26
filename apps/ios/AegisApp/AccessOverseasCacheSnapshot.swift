import AccessKit
import AegisPolicyKit
import Foundation

struct AccessOverseasSelection: Codable, Equatable, Sendable {
    enum Mode: String, CaseIterable, Codable, Sendable { case categories, all }

    var enabled: Bool
    let mode: Mode
    let categories: [AccessOverseasCategory]

    init(enabled: Bool = false, mode: Mode = .categories, categories: Set<AccessOverseasCategory> = []) {
        self.enabled = enabled
        self.mode = mode
        self.categories = categories.sorted { $0.rawValue < $1.rawValue }
    }

    var scope: AccessOverseasCatalogue.Scope { mode == .all ? .all : .categories(Set(categories)) }

    var isCanonical: Bool {
        categories == Set(categories).sorted { $0.rawValue < $1.rawValue }
    }
}

/// A prepared release and its effective policy. A staged release has no user
/// selection. An active policy is bounded by the approved selection and may
/// be narrower than the release while an expansion awaits confirmation.
struct AccessOverseasCacheSnapshot: Sendable {
    typealias Admission = AccessGeoSiteAdmission
    typealias Policy = AccessOverseasCatalogue.Policy

    struct Reference: Codable, Equatable, Sendable {
        let digest: String
        let length: Int
        let receipt: Admission.Receipt

        var files: [String] {
            [try? AccessGeoSiteStorage.overseasName(digest, raw: false),
             try? AccessGeoSiteStorage.overseasName(receipt.database.sha256, raw: true)].compactMap { $0 }
        }

        func isValid(highWater: Admission.Receipt?) -> Bool {
            guard let highWater, (1...AccessGeoSiteStorage.overseasBlobLimit).contains(length),
                  Admission.isSHA256(digest), (try? receipt.validityDeadline()) != nil,
                  receipt.tag >= AccessGeoSiteCatalogue.bundled.tag, receipt.tag <= highWater.tag,
                  receipt.tag != highWater.tag || receipt == highWater else { return false }
            return receipt.tag != AccessGeoSiteCatalogue.bundled.tag || receipt.database.sha256 == AccessGeoSiteCatalogue.bundled.rawSHA256
        }
    }

    private struct Blob: Codable, Sendable {
        let format: Int
        let owner: UUID
        let receipt: Admission.Receipt
        let suffixListSHA256: String
        let checksum: Data
        let approved: AccessOverseasSelection?
        let rules: [AccessOverseasCatalogue.Record]
        let exclusions: [AccessOverseasCatalogue.Record]
    }

    let receipt: Admission.Receipt
    let expiresAt: Date
    let suffixListSHA256: String
    let catalogue: AccessOverseasCatalogue
    let source: Admission.OverseasSource
    let approved: AccessOverseasSelection?
    let fullPolicy: Policy
    let policy: Policy

    init(_ candidate: Admission.Candidate) throws {
        guard let catalogue = candidate.overseas, let source = candidate.overseasSource else {
            throw AccessGeoSiteCache.Failure.ineligible
        }
        receipt = candidate.receipt
        expiresAt = candidate.expiresAt
        suffixListSHA256 = candidate.suffixListSHA256
        self.catalogue = catalogue
        self.source = source
        approved = nil
        let full = try catalogue.policy(for: .all)
        fullPolicy = full
        policy = full
    }

    private init(source snapshot: Self, approved: AccessOverseasSelection?, policy: Policy) {
        receipt = snapshot.receipt
        expiresAt = snapshot.expiresAt
        suffixListSHA256 = snapshot.suffixListSHA256
        catalogue = snapshot.catalogue
        source = snapshot.source
        self.approved = approved
        fullPolicy = snapshot.fullPolicy
        self.policy = policy
    }

    func approving(_ selection: AccessOverseasSelection) throws -> Self {
        let scoped = selection.mode == .all ? fullPolicy : try catalogue.policy(for: selection.scope)
        return Self(source: self, approved: selection, policy: scoped)
    }

    func narrowed(to selection: AccessOverseasSelection, retaining prior: Self) throws -> Self? {
        let next = selection.mode == .all ? fullPolicy : try catalogue.policy(for: selection.scope)
        guard let retained = next.intersection(with: prior.policy) else { return nil }
        return Self(source: self, approved: selection, policy: retained)
    }

    func seal(owner: UUID, storage: AccessGeoSiteStorage) throws -> Reference {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let blob = Blob(format: 1, owner: owner, receipt: receipt, suffixListSHA256: suffixListSHA256,
                        checksum: source.checksum, approved: approved,
                        rules: policy.rules, exclusions: policy.exclusions)
        let bytes = try encoder.encode(blob)
        let digest = Admission.sha256(bytes)
        guard bytes.count <= AccessGeoSiteStorage.overseasBlobLimit else { throw AccessGeoSiteCache.Failure.unavailable }
        try storage.storeOverseas(source.database, digest: receipt.database.sha256, raw: true)
        try storage.storeOverseas(bytes, digest: digest, raw: false)
        return Reference(digest: digest, length: bytes.count, receipt: receipt)
    }

    static func recover(_ reference: Reference, owner: UUID, approved: AccessOverseasSelection?,
                        storage: AccessGeoSiteStorage, now: Date, verified: Self? = nil) throws -> Self {
        let bytes = try storage.readOverseas(digest: reference.digest, length: reference.length, raw: false)
        let blob = try JSONDecoder().decode(Blob.self, from: bytes)
        guard blob.format == 1, blob.owner == owner, blob.receipt == reference.receipt,
              blob.approved == approved, blob.suffixListSHA256 == RegisteredDomain.verifiedGeoSiteSuffixListSHA256
        else { throw AccessGeoSiteCache.Failure.unavailable }
        let receipt = blob.receipt
        let offered: Self
        if let verified, verified.receipt == receipt, verified.source.checksum == blob.checksum {
            // A single cold restore can verify the same official bytes once
            // even when both independently hashed pointers refer to them.
            offered = verified
        } else {
            let database = try storage.readOverseas(digest: receipt.database.sha256,
                                                    length: receipt.database.byteCount, raw: true)
            // Recompile expired data to identify which requests must be held.
            // Its original deadline is retained and never extended.
            let verifiedAt = min(now, try receipt.validityDeadline().addingTimeInterval(-1))
            let candidate = try Admission.admit(receipt: receipt, database: database, checksum: blob.checksum,
                                               now: verifiedAt, includeOverseas: true)
            offered = try Self(candidate)
        }
        let policy = try Policy(rules: blob.rules, exclusions: blob.exclusions)
        guard policy.rules == blob.rules, policy.exclusions == blob.exclusions else {
            throw AccessGeoSiteCache.Failure.unavailable
        }
        if let approved {
            let present = approved.mode == .all ? offered.fullPolicy : try offered.catalogue.policy(for: approved.scope)
            let expansion = policy.expansion(over: present)
            guard approved.isCanonical, expansion.rules.isEmpty, expansion.removedExclusions.isEmpty else {
                throw AccessGeoSiteCache.Failure.unavailable
            }
        } else {
            guard policy == offered.fullPolicy else { throw AccessGeoSiteCache.Failure.unavailable }
        }
        return Self(source: offered, approved: approved, policy: policy)
    }
}
