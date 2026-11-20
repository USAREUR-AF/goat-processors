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

/// Ranking, the total: the chosen entries in ascending order of value,
/// added left to right from 0. Any arrangement of the same values gives the
/// same total, bit for bit. Pure.
pub(crate) fn total(values: &[f64]) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(|x, y| x.partial_cmp(y).unwrap());
    sorted.iter().fold(0.0, |sum, v| sum + v)
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
            let total = total(&values);
            Assignment { index, values, total }
        })
        .collect();
    ranked.sort_by(|x, y| x.total.partial_cmp(&y.total).unwrap().then_with(|| x.index.cmp(&y.index)));
    ranked.truncate(k);
    ranked
}

#[cfg(test)]
mod tests {
    use super::{ranked_assignments, total, Entries};

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

    fn entries(rows: Vec<Vec<Option<f64>>>, alone: Vec<f64>) -> Entries {
        let columns = (1..=rows.first().map_or(0, |r| r.len() as u64)).collect();
        Entries { columns, rows, alone }
    }

    #[test]
    fn forbidden_entries_and_alone_come_after_columns() {
        // One entity, a forbidden column and an allowed one: [1] then alone [2].
        let r = ranked_assignments(&entries(vec![vec![None, Some(4.0)]], vec![4.0]), 5);
        assert_eq!(r.iter().map(|a| a.index.clone()).collect::<Vec<_>>(), vec![vec![1], vec![2]]);
        assert_eq!(r[0].values, vec![4.0]);
    }

    #[test]
    fn no_column_twice_and_k_truncates() {
        let e = entries(vec![vec![Some(1.0)], vec![Some(1.0)]], vec![5.0, 6.0]);
        let r = ranked_assignments(&e, 10);
        // [0,1] (1+6), [1,0] (5+1), [1,1] (5+6): never [0,0].
        assert_eq!(r.iter().map(|a| a.index.clone()).collect::<Vec<_>>(), vec![vec![1, 0], vec![0, 1], vec![1, 1]]);
        assert_eq!(ranked_assignments(&e, 1).len(), 1);
    }

    #[test]
    fn the_total_adds_the_chosen_entries_in_ascending_order() {
        // 1e16 + 1 + 1 in ascending order is 1e16 + 2 exactly; left to right it would lose both.
        let e = entries(vec![vec![Some(1e16), None, None], vec![None, Some(1.0), None], vec![None, None, Some(1.0)]], vec![1e30; 3]);
        assert_eq!(ranked_assignments(&e, 1)[0].total, 1.0 + 1.0 + 1e16);
    }

    #[test]
    fn no_rows_is_one_empty_assignment() {
        let r = ranked_assignments(&entries(vec![], vec![]), 3);
        assert_eq!((r.len(), r[0].total), (1, 0.0));
    }

    /// A seeded generator for the properties below (splitmix64).
    struct Rng(u64);

    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = self.0;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }
        fn below(&mut self, n: u64) -> u64 {
            self.next() % n
        }
        fn value(&mut self) -> f64 {
            // Few distinct values, so that equal totals and ties are common.
            [0.5, 1.0, 1.5, 2.0, 3.25, 7.0, 9.21, -2.0][self.below(8) as usize] + if self.below(4) == 0 { 0.1 } else { 0.0 }
        }
    }

    /// Random entries: up to 5 entities, up to 5 columns, some forbidden.
    fn random_entries(rng: &mut Rng) -> Entries {
        let (n, m) = (rng.below(6) as usize, rng.below(6) as usize);
        let rows = (0..n).map(|_| (0..m).map(|_| if rng.below(3) == 0 { None } else { Some(rng.value()) }).collect()).collect();
        let alone = (0..n).map(|_| rng.value()).collect();
        Entries { columns: (1..=m as u64).collect(), rows, alone }
    }

    #[test]
    fn the_total_does_not_depend_on_the_arrangement() {
        let mut rng = Rng(5);
        for _ in 0..2000 {
            let mut values: Vec<f64> = (0..rng.below(8)).map(|_| rng.value() * 1e3f64.powi(rng.below(5) as i32)).collect();
            let t = total(&values);
            for i in (1..values.len()).rev() {
                values.swap(i, rng.below(i as u64 + 1) as usize);
            }
            assert_eq!(t.to_bits(), total(&values).to_bits(), "{:?}", values);
        }
    }

    /// Every assignment, by the definition: each entity a free allowed
    /// column or alone, ranked by (total, choice vector).
    fn reference(e: &Entries) -> Vec<(Vec<usize>, f64)> {
        let (n, m) = (e.rows.len(), e.columns.len());
        let mut all: Vec<Vec<usize>> = vec![Vec::new()];
        for i in 0..n {
            all = all
                .into_iter()
                .flat_map(|prefix| {
                    (0..=m)
                        .filter(|&j| j == m || (e.rows[i][j].is_some() && !prefix.contains(&j)))
                        .map(|j| {
                            let mut p = prefix.clone();
                            p.push(j);
                            p
                        })
                        .collect::<Vec<_>>()
                })
                .collect();
        }
        let mut ranked: Vec<(Vec<usize>, f64)> = all
            .into_iter()
            .map(|idx| {
                let values: Vec<f64> = idx.iter().enumerate().map(|(i, &j)| if j == m { e.alone[i] } else { e.rows[i][j].unwrap() }).collect();
                let t = total(&values);
                (idx, t)
            })
            .collect();
        ranked.sort_by(|x, y| x.1.partial_cmp(&y.1).unwrap().then_with(|| x.0.cmp(&y.0)));
        ranked
    }

    #[test]
    fn ranked_assignments_are_the_first_k_of_the_strict_order() {
        let mut rng = Rng(23);
        for _ in 0..3000 {
            let e = random_entries(&mut rng);
            let k = 1 + rng.below(6) as usize;
            let want = reference(&e);
            let got = ranked_assignments(&e, k);
            assert_eq!(got.len(), want.len().min(k));
            for (g, (idx, t)) in got.iter().zip(&want) {
                assert_eq!((&g.index, g.total.to_bits()), (idx, t.to_bits()));
                let m = e.columns.len();
                let values: Vec<f64> = g.index.iter().enumerate().map(|(i, &j)| if j == m { e.alone[i] } else { e.rows[i][j].unwrap() }).collect();
                assert_eq!(g.values, values);
            }
        }
    }
}
