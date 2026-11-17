import struct

import pytest

from coleira_ml import sync_protocol as sp


def test_record_layout_matches_contract_4_7():
    r = sp.MinuteRecord(1800000000, (30, 30, 0, 0, 0, 0, 0), 0, 77, sp.FLAG_BATTERY_NOT_MEASURED)
    raw = sp.encode_record(r)
    assert len(raw) == 15
    assert raw[0] == 1
    assert struct.unpack_from("<I", raw, 1)[0] == 1800000000
    assert list(raw[5:12]) == [30, 30, 0, 0, 0, 0, 0]
    assert sp.decode_record(raw) == r
    assert r.total == 60


def test_control_and_time_payloads():
    assert sp.time_payload(0x01020304) == bytes([4, 3, 2, 1])
    assert sp.send_since_payload(0x01020304) == bytes([0x01, 4, 3, 2, 1])
    assert sp.STATUS_REQUEST == b"\x02"


def test_status_parsing():
    buf = struct.pack("<BBBBIII", sp.KIND_SYNC_DONE, 1, 0, 0, 42, 1800000000, 1800002460)
    st = sp.parse_status(buf)
    assert st.kind == sp.KIND_SYNC_DONE and st.clock_set and st.count == 42
    assert st.newest_minute_ts - st.oldest_minute_ts == 41 * 60
    with pytest.raises(ValueError):
        sp.parse_status(buf[:-1])


def test_data_notifications_split_into_whole_records():
    recs = [
        sp.encode_record(sp.MinuteRecord(1800000000 + 60 * i, (60, 0, 0, 0, 0, 0, 0), 0, 0, 1))
        for i in range(16)
    ]
    assert sp.split_records(b"".join(recs)) == recs
    with pytest.raises(ValueError):
        sp.split_records(b"".join(recs)[:-1])
