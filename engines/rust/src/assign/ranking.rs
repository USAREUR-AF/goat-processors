//! correlate-assign.md Ranking: the choice vector, the total, and the
//! first `k` assignments of one source; and the entries they choose from
//! (Assignment of one source, steps 1 and 2, as data).

/// What one entity of R chooses.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Choice {
    Column(u64),
    Alone,
}

/// Steps 1 and 2 for one source against one membership.
pub(crate) struct Entries {
    /// Column system numbers, in creation order.
    pub(crate) columns: Vec<u64>,
    /// Per entity of R, per column: the entry, or None when forbidden.
    pub(crate) rows: Vec<Vec<Option<f64>>>,
    /// Per entity of R: its *alone* entry.
    pub(crate) alone: Vec<f64>,
}

/// One assignment: per entity of R, its choice index (a column's position, or
/// the number of columns for *alone*) and the entry it chose.
#[derive(Debug, Clone)]
pub(crate) struct Assignment {
    pub(crate) index: Vec<usize>,
    pub(crate) values: Vec<f64>,
    pub(crate) total: f64,
}

/// Ranking: the first `k` assignments, by total, then by choice vector. Brute
/// force over every assignment, which is exact and fine at vector sizes.
pub(crate) fn ranked_assignments(e: &Entries, k: usize) -> Vec<Assignment> {
    fn extend(e: &Entries, i: usize, used: &mut Vec<bool>, index: &mut Vec<usize>, all: &mut Vec<Vec<usize>>) {
        if i == e.rows.len() {
            all.push(index.clone());
            return;
        }
        let m = e.columns.len();
        for j in 0..=m {
            let allowed = j == m || (!used[j] && e.rows[i][j].is_some());
            if !allowed {
                continue;
            }
            if j < m {
                used[j] = true;
            }
            index.push(j);
            extend(e, i + 1, used, index, all);
            index.pop();
            if j < m {
                used[j] = false;
            }
        }
    }
    let mut all = Vec::new();
    extend(e, 0, &mut vec![false; e.columns.len()], &mut Vec::new(), &mut all);

    let m = e.columns.len();
    let mut ranked: Vec<Assignment> = all
        .into_iter()
        .map(|index| {
            let values: Vec<f64> = index.iter().enumerate().map(|(i, &j)| if j == m { e.alone[i] } else { e.rows[i][j].unwrap() }).collect();
            // The total: chosen entries in ascending order, added from 0.
            let mut sorted = values.clone();
            sorted.sort_by(|x, y| x.partial_cmp(y).unwrap());
            let total = sorted.iter().fold(0.0, |sum, v| sum + v);
            Assignment { index, values, total }
        })
        .collect();
    ranked.sort_by(|x, y| x.total.partial_cmp(&y.total).unwrap().then_with(|| x.index.cmp(&y.index)));
    ranked.truncate(k);
    ranked
}

#[cfg(test)]
mod tests {
    use super::{ranked_assignments, Entries};

    #[test]
    fn ranking_breaks_equal_totals_by_choice_vector() {
        // Both full matchings total 3.0 bit for bit; the smaller choice vector
        // [0, 1] comes first. Then [0, 2] and [2, 0] tie at 10.0.
        let e = Entries { columns: vec![1, 2], rows: vec![vec![Some(1.0), Some(2.0)], vec![Some(1.0), Some(2.0)]], alone: vec![9.0, 9.0] };
        let r = ranked_assignments(&e, 3);
        assert_eq!(r[0].index, vec![0, 1]);
        assert_eq!(r[1].index, vec![1, 0]);
        assert_eq!(r[0].total, r[1].total);
        assert_eq!(r[2].index, vec![0, 2]);
    }
}
