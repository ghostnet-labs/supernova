use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

pub fn pane_count(tiled: usize, floating: usize, active: bool) -> usize {
    let count = tiled + floating;
    if active {
        count.saturating_sub(1)
    } else {
        count
    }
}

pub fn viewport_range(total: usize, data_rows: usize, selected: Option<usize>) -> (usize, usize) {
    if data_rows >= total {
        return (0, total);
    }
    let anchor = selected.unwrap_or(0);
    let mut start = anchor.saturating_sub(data_rows / 2);
    let mut end = start + data_rows;
    if end > total {
        end = total;
        start = total.saturating_sub(data_rows);
    }
    (start, end)
}

pub fn compute_reduction_tier(
    full_name_width: usize,
    full_details_width: usize,
    full_tag_width: usize,
    full_fourth_width: usize,
    abbreviated_details_width: usize,
    short_fourth_width: usize,
    max_width: usize,
) -> (bool, bool, bool, Option<usize>) {
    let full_total = full_name_width + full_details_width + full_tag_width + full_fourth_width + 4;
    if full_total <= max_width {
        return (false, false, false, None);
    }

    let abbreviated_details_total =
        full_name_width + abbreviated_details_width + full_tag_width + full_fourth_width + 4;
    if abbreviated_details_total <= max_width {
        return (true, false, false, None);
    }

    let abbreviated_tag_width = 3;
    let abbreviated_tag_total =
        full_name_width + abbreviated_details_width + abbreviated_tag_width + full_fourth_width + 4;
    if abbreviated_tag_total <= max_width {
        return (true, true, false, None);
    }

    let abbreviated_fourth_total = full_name_width
        + abbreviated_details_width
        + abbreviated_tag_width
        + short_fourth_width
        + 4;
    if abbreviated_fourth_total <= max_width {
        return (true, true, true, None);
    }

    let name_width = max_width
        .saturating_sub(abbreviated_details_width + abbreviated_tag_width + short_fourth_width + 4);
    (true, true, true, Some(name_width))
}

pub fn truncate_to_width(text: &str, max_width: usize) -> String {
    let mut result = String::new();
    let mut width = 0;
    for character in text.chars() {
        let character_width = character.width().unwrap_or(0);
        if width + character_width > max_width {
            break;
        }
        result.push(character);
        width += character_width;
    }
    result
}

pub fn text_width(text: &str) -> usize {
    text.width()
}

pub fn subsequence_indices(text: &str, query: &str) -> Option<Vec<usize>> {
    let mut text_chars = text.chars().enumerate();
    let mut indices = Vec::with_capacity(query.chars().count());
    for query_char in query.chars() {
        let query_char = query_char.to_lowercase().to_string();
        let (index, _) =
            text_chars.find(|(_, text_char)| text_char.to_lowercase().to_string() == query_char)?;
        indices.push(index);
    }
    Some(indices)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuzzy_match_is_case_insensitive_and_reports_character_positions() {
        assert_eq!(subsequence_indices("Editor", "edr"), Some(vec![0, 1, 5]));
        assert_eq!(subsequence_indices("Editor", "EDR"), Some(vec![0, 1, 5]));
        assert_eq!(subsequence_indices("Editor", "logs"), None);
    }

    #[test]
    fn pane_count_excludes_the_picker_from_the_active_tab() {
        assert_eq!(pane_count(2, 1, true), 2);
        assert_eq!(pane_count(2, 1, false), 3);
        assert_eq!(pane_count(0, 0, true), 0);
    }

    #[test]
    fn viewport_tracks_selection_like_the_session_manager() {
        assert_eq!(viewport_range(3, 4, None), (0, 3));
        assert_eq!(viewport_range(10, 3, None), (0, 3));
        assert_eq!(viewport_range(10, 3, Some(5)), (4, 7));
        assert_eq!(viewport_range(10, 3, Some(9)), (7, 10));
    }

    #[test]
    fn columns_abbreviate_before_names_are_truncated() {
        assert_eq!(
            compute_reduction_tier(10, 8, 6, 14, 2, 5, 42),
            (false, false, false, None)
        );
        assert_eq!(
            compute_reduction_tier(10, 8, 6, 14, 2, 5, 36),
            (true, false, false, None)
        );
        assert_eq!(
            compute_reduction_tier(10, 8, 6, 14, 2, 5, 33),
            (true, true, false, None)
        );
        assert_eq!(
            compute_reduction_tier(10, 8, 6, 14, 2, 5, 22),
            (true, true, true, Some(8))
        );
    }

    #[test]
    fn truncation_uses_terminal_column_width() {
        assert_eq!(truncate_to_width("a界b", 2), "a");
        assert_eq!(truncate_to_width("a界b", 3), "a界");
        assert_eq!(text_width("a界b"), 4);
    }
}
