use crate::engine::download::SegmentInfo;

pub fn split_into_segments(total_bytes: u64, count: u8) -> Vec<SegmentInfo> {
    if count == 0 || total_bytes == 0 {
        return vec![];
    }
    let chunk = total_bytes / count as u64;
    (0..count)
        .map(|i| {
            let start = i as u64 * chunk;
            let end = if i == count - 1 {
                total_bytes
            } else {
                start + chunk
            };
            SegmentInfo {
                index: i,
                start_byte: start,
                end_byte: end,
                downloaded_bytes: 0,
                active: false,
            }
        })
        .collect()
}
