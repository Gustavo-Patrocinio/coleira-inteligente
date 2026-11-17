import numpy as np
import pytest

from coleira_ml import raw_packet as rp


def _samples():
    return np.arange(60, dtype=np.int16).reshape(10, 6) * np.int16(-37)


def test_packet_size_matches_contract():
    assert rp.PACKET_SIZE == 128


def test_known_bytes_header_is_little_endian():
    buf = rp.pack(seq=0x1234, device_ms=0xA1B2C3D4, samples=_samples())
    assert buf[:8] == bytes([1, 1, 0x34, 0x12, 0xD4, 0xC3, 0xB2, 0xA1])
    # first sample, ax = 0, ay = -37 → 0xFFDB little-endian
    assert buf[8:12] == bytes([0x00, 0x00, 0xDB, 0xFF])


def test_round_trip():
    s = _samples()
    pkt = rp.parse(rp.pack(65535, 123456, s))
    assert pkt.seq == 65535 and pkt.device_ms == 123456
    assert np.array_equal(pkt.samples, s)


@pytest.mark.parametrize(
    ("mutate", "msg"),
    [
        (lambda b: b[:-1], "expected 128"),
        (lambda b: bytes([2]) + b[1:], "version"),
        (lambda b: b[:1] + bytes([7]) + b[2:], "type"),
    ],
)
def test_parse_rejects_bad_packets(mutate, msg):
    with pytest.raises(ValueError, match=msg):
        rp.parse(mutate(rp.pack(1, 2, _samples())))


def test_csv_rows_follow_contract_4_5():
    rows = rp.csv_rows(rp.parse(rp.pack(7, 1000, _samples())), phone_ts_ms=5000)
    assert len(rows) == 10
    assert rows[0][:3] == [5000, 1000, 7]
    assert rows[9][1] == 1000 + 9 * 20
    assert len(rows[0]) == len(rp.CSV_HEADER)


def test_loss_counter_handles_wrap_and_gaps():
    c = rp.LossCounter()
    for s in [65533, 65534, 65535, 0, 2, 3]:  # packet 1 lost after the wrap
        c.add(s)
    assert c.expected == 7
    assert c.received == 6
    assert c.loss == pytest.approx(1 / 7)
