"""Read DNS subject alternative names for diagnostic evidence from an X.509 leaf."""
import re


def der_items(data):
    """Yield each tag's initial octet and its value, preserving class and form."""
    cursor = 0
    while cursor < len(data):
        tag = data[cursor]
        cursor += 1
        number = tag & 0x1f
        if tag & 0xc0 == 0:
            constructed = bool(tag & 0x20)
            if number in (0, 15) or constructed != (number in (8, 11, 16, 17, 29)):
                raise ValueError("Invalid universal DER tag form")
        if number == 0x1f:
            if cursor == len(data) or data[cursor] < 31 or data[cursor] == 0x80:
                raise ValueError("Invalid high DER tag")
            while cursor < len(data) and data[cursor] & 0x80:
                cursor += 1
            if cursor == len(data):
                raise ValueError("Truncated high DER tag")
            cursor += 1
        if cursor == len(data):
            raise ValueError("Truncated DER header")
        length = data[cursor]
        cursor += 1
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


def validate_oid(value):
    if not value or value[-1] & 0x80 or re.search(rb"(?:^|[\x00-\x7f])\x80", value):
        raise ValueError("Invalid object identifier")


def validate_der_tree(tag, value):
    """Check the nested boundaries of constructed values with an open ASN.1 type."""
    pending = [der_items(memoryview(value))] if tag & 0x20 else []
    while pending:
        item = next(pending[-1], None)
        if item is None:
            pending.pop()
        else:
            child, body = item
            if child & 0x20:
                if len(pending) >= 64:
                    raise ValueError("Excessively nested DER value")
                pending.append(der_items(body))


def validate_directory_name(value):
    for tag, body in sequence(value):
        attributes = list(der_items(body))
        if tag != 0x31 or not attributes:
            raise ValueError("Invalid relative distinguished name")
        for attribute_tag, attribute in attributes:
            fields = list(der_items(attribute))
            if attribute_tag != 0x30 or len(fields) != 2 or fields[0][0] != 0x06:
                raise ValueError("Invalid distinguished name attribute")
            validate_oid(fields[0][1])
            validate_der_tree(*fields[1])


def validate_non_dns_name(tag, value):
    if tag in (0x81, 0x86):  # rfc822Name or uniformResourceIdentifier.
        if not value or not value.isascii():
            raise ValueError("Invalid IA5String in subjectAltName")
    elif tag == 0x87:
        if len(value) not in (4, 16):
            raise ValueError("Invalid IP address in subjectAltName")
    elif tag == 0x88:
        validate_oid(value)
    elif tag == 0xa4:
        validate_directory_name(value)
    elif tag == 0xa0:  # otherName, a type identifier and an explicitly tagged value.
        fields = list(der_items(value))
        if [field for field, _ in fields] != [0x06, 0xa0]:
            raise ValueError("Invalid otherName")
        validate_oid(fields[0][1])
        item, = der_items(fields[1][1])
        validate_der_tree(*item)
    elif tag == 0xa5:  # ediPartyName, an optional assigner and a required party name.
        fields = list(der_items(value))
        if [field for field, _ in fields] not in ([0xa1], [0xa0, 0xa1]):
            raise ValueError("Invalid ediPartyName")
        for _, body in fields:
            (string_tag, string), = der_items(body)
            if string_tag not in (0x0c, 0x13, 0x14, 0x1c, 0x1e) or not string:
                raise ValueError("Invalid ediPartyName string")
    elif tag == 0xa3:  # x400Address, a constructed ORAddress.
        fields = list(der_items(value))
        if [field for field, _ in fields] not in ([0x30], [0x30, 0x30], [0x30, 0x31], [0x30, 0x30, 0x31]):
            raise ValueError("Invalid x400Address")
        for item in fields:
            validate_der_tree(*item)
    else:
        raise ValueError("Invalid GeneralName tag")


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
        if tag == 0x82:  # [2] IMPLICIT IA5String, dNSName.
            if not re.fullmatch(rb"(?:\*\.)?[A-Za-z0-9.-]+", value):
                raise ValueError("Invalid dNSName")
            names.append(value.decode("ascii"))
        else:
            validate_non_dns_name(tag, value)
    return names
