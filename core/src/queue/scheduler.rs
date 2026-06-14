use chrono::NaiveTime;

#[derive(Debug, Clone)]
pub struct ScheduleWindow {
    pub start: NaiveTime,
    pub end: NaiveTime,
}

impl ScheduleWindow {
    pub fn off_peak_default() -> Self {
        Self {
            start: NaiveTime::from_hms_opt(23, 0, 0).unwrap(),
            end: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
        }
    }

    pub fn is_active_now(&self) -> bool {
        let now = chrono::Local::now().time();
        if self.start < self.end {
            now >= self.start && now < self.end
        } else {
            now >= self.start || now < self.end
        }
    }
}
