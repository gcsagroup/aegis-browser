"""Read DNS subject alternative names for diagnostic evidence from an X.509 leaf."""
import re


def der_items(data):
    """Yield the one-byte tags and values used by the certificate and SAN envelopes."""
    cursor = 0
    while cursor < len(data):
        if cursor + 2 > len(data):
            raise ValueError("Truncated DER header")
        tag, length = data[cursor:cursor + 2]
        cursor += 2
        if tag & 0x1f == 0x1f:
            raise ValueError("Unexpected DER tag")
        if length >= 128:
            count = length & 0x7f
            if not 1 <= count <= 4 or cursor + count > len(data) or data[cursor] == 0:
                raise ValueError("Invalid DER length")
            length = int.from_bytes(data[cursor:cursor + count], "big")
            cursor += count
            if length < 128:
                raise ValueError("Non-canonical DER length")
        end = cursor + length
        if end > len(data):
            raise ValueError("Truncated DER value")
        yield tag, data[cursor:end]
        cursor = end


def sequence(data):
    (tag, body), = der_items(data)
    if tag != 0x30:
        raise ValueError("Expected a DER sequence")
    return list(der_items(body))


def dns_subject_alternative_names(certificate):
    """Decode GeneralName dNSName values. An absent SAN returns an empty list."""
    fields = sequence(certificate)
    if [tag for tag, _ in fields] != [0x30, 0x30, 0x03]:
        raise ValueError("Invalid X.509 certificate envelope")
    tbs = list(der_items(fields[0][1]))
    if tbs and tbs[0][0] == 0xa0:
        tbs = tbs[1:]
    if [tag for tag, _ in tbs[:6]] != [0x02, 0x30, 0x30, 0x30, 0x30, 0x30]:
        raise ValueError("Invalid X.509 certificate body")
    optional_tags = [tag for tag, _ in tbs[6:]]
    if optional_tags != sorted(set(optional_tags)) or set(optional_tags) - {0x81, 0x82, 0xa3}:
        raise ValueError("Invalid optional certificate fields")
    if 0xa3 not in optional_tags:
        return []

    san = None
    for tag, body in sequence(tbs[-1][1]):
        if tag != 0x30:
            raise ValueError("Invalid X.509 extension")
        fields = list(der_items(body))
        if [field_tag for field_tag, _ in fields] not in ([0x06, 0x04], [0x06, 0x01, 0x04]):
            raise ValueError("Invalid X.509 extension fields")
        if fields[0][1] == b"\x55\x1d\x11":  # 2.5.29.17, subjectAltName.
            if san is not None:
                raise ValueError("Duplicate subjectAltName extension")
            san = fields[-1][1]
    if san is None:
        return []

    general_names = sequence(san)
    if not general_names:
        raise ValueError("Empty subjectAltName extension")
    names = []
    for tag, value in general_names:
        if tag not in (0xa0, 0x81, 0x82, 0xa3, 0xa4, 0xa5, 0x86, 0x87, 0x88):
            raise ValueError("Invalid GeneralName tag")
        if tag == 0x82:  # [2] IMPLICIT IA5String, dNSName.
            if not re.fullmatch(rb"(?:\*\.)?[A-Za-z0-9.-]+", value):
                raise ValueError("Invalid dNSName")
            names.append(value.decode("ascii"))
    return names
