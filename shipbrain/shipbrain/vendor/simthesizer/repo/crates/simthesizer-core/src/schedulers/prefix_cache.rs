use std::collections::{hash_map::Entry, HashMap};
use std::hash::{Hash, Hasher};

#[derive(Debug)]
struct BlockEntry {
    ref_count: u32,
    lru_prev: Option<u64>,
    lru_next: Option<u64>,
}

#[derive(Debug, Default)]
pub struct PrefixCache {
    cache: HashMap<u64, BlockEntry>,
    lru_head: Option<u64>,
    lru_tail: Option<u64>,
}

impl PrefixCache {
    pub fn bytes_used(&self, block_size: u32, kv_bytes_per_token_per_device: u64) -> u64 {
        self.cache.len() as u64 * u64::from(block_size) * kv_bytes_per_token_per_device
    }

    pub fn longest_hit(&mut self, hashes: &[u64]) -> usize {
        let mut count = 0;
        for &h in hashes {
            if !self.cache.contains_key(&h) {
                break;
            }
            self.touch(h);
            count += 1;
        }
        count
    }

    pub fn insert(&mut self, hashes: &[u64]) {
        for &h in hashes {
            if let Entry::Vacant(entry) = self.cache.entry(h) {
                entry.insert(BlockEntry {
                    ref_count: 0,
                    lru_prev: None,
                    lru_next: None,
                });
                self.lru_push_back(h);
            } else {
                self.touch(h);
            }
        }
    }

    pub fn lock(&mut self, hashes: &[u64]) {
        for &h in hashes {
            if self.cache[&h].ref_count == 0 {
                self.lru_remove(h);
            }
            self.cache.get_mut(&h).unwrap().ref_count += 1;
        }
    }

    pub fn unlock(&mut self, hashes: &[u64]) {
        // Preserve earlier prefixes when several blocks become evictable together.
        for &h in hashes.iter().rev() {
            let entry = self.cache.get_mut(&h).unwrap();
            assert!(entry.ref_count > 0, "releasing an unreferenced cache block");
            entry.ref_count -= 1;
            if entry.ref_count == 0 {
                self.lru_push_back(h);
            }
        }
    }

    pub fn evict_one(&mut self) -> bool {
        let Some(h) = self.lru_head else {
            return false;
        };
        self.lru_remove(h);
        self.cache.remove(&h);
        true
    }

    fn touch(&mut self, h: u64) {
        if self.cache[&h].ref_count == 0 {
            self.lru_remove(h);
            self.lru_push_back(h);
        }
    }

    fn lru_push_back(&mut self, h: u64) {
        let entry = self.cache.get_mut(&h).unwrap();
        entry.lru_prev = self.lru_tail;
        entry.lru_next = None;

        if let Some(old_tail) = self.lru_tail {
            self.cache.get_mut(&old_tail).unwrap().lru_next = Some(h);
        } else {
            self.lru_head = Some(h);
        }
        self.lru_tail = Some(h);
    }

    fn lru_remove(&mut self, h: u64) {
        let entry = self.cache.get_mut(&h).unwrap();
        let prev = entry.lru_prev.take();
        let next = entry.lru_next.take();

        match prev {
            Some(p) => self.cache.get_mut(&p).unwrap().lru_next = next,
            None => self.lru_head = next,
        }
        match next {
            Some(n) => self.cache.get_mut(&n).unwrap().lru_prev = prev,
            None => self.lru_tail = prev,
        }
    }
}

pub(super) fn hash_block(parent_hash: u64, first: &[u32], second: &[u32]) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    parent_hash.hash(&mut hasher);
    (first.len() + second.len()).hash(&mut hasher);
    u32::hash_slice(first, &mut hasher);
    u32::hash_slice(second, &mut hasher);
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hashes(tokens: &[u32]) -> Vec<u64> {
        let mut parent = 0;
        tokens
            .as_chunks::<16>()
            .0
            .iter()
            .map(|chunk| {
                parent = hash_block(parent, chunk, &[]);
                parent
            })
            .collect()
    }

    fn hit(cache: &mut PrefixCache, tokens: &[u32]) -> usize {
        cache.longest_hit(&hashes(tokens)) * 16
    }

    fn tokens(n: usize) -> Vec<u32> {
        (0..n as u32).collect()
    }

    #[test]
    fn empty_cache_returns_zero_hit() {
        let mut cache = PrefixCache::default();
        assert_eq!(hit(&mut cache, &tokens(32)), 0);
    }

    #[test]
    fn insert_and_hit_single_block() {
        let mut cache = PrefixCache::default();
        let toks = tokens(16);
        cache.insert(&hashes(&toks));
        assert_eq!(hit(&mut cache, &toks), 16);
    }

    #[test]
    fn hit_returns_block_aligned_length() {
        let mut cache = PrefixCache::default();
        let toks = tokens(16);
        cache.insert(&hashes(&toks));
        assert_eq!(hit(&mut cache, &tokens(20)), 16);
    }

    #[test]
    fn chain_hash_validates_prefix() {
        let mut cache = PrefixCache::default();
        cache.insert(&hashes(&tokens(16)));
        cache.insert(&hashes(&tokens(32)));
        assert_eq!(hit(&mut cache, &tokens(32)), 32);

        let mut bad_prefix: Vec<u32> = vec![999; 16];
        bad_prefix.extend(16..32u32);
        assert_eq!(hit(&mut cache, &bad_prefix), 0);
    }

    #[test]
    fn insert_idempotent() {
        let mut cache = PrefixCache::default();
        let toks = tokens(16);
        cache.insert(&hashes(&toks));
        cache.insert(&hashes(&toks));
        assert_eq!(cache.bytes_used(16, 1), 16);
    }

    #[test]
    fn lock_prevents_eviction() {
        let mut cache = PrefixCache::default();
        let toks = tokens(16);
        cache.insert(&hashes(&toks));
        cache.lock(&hashes(&toks));
        assert!(!cache.evict_one());
        cache.unlock(&hashes(&toks));
        assert!(cache.evict_one());
    }

    #[test]
    fn evict_removes_lru_first() {
        let mut cache = PrefixCache::default();
        let a = tokens(16);
        let b: Vec<u32> = (100..116).collect();

        cache.insert(&hashes(&a));
        cache.insert(&hashes(&b));

        assert!(cache.evict_one());
        assert_eq!(hit(&mut cache, &a), 0);
        assert_eq!(hit(&mut cache, &b), 16);
    }

    #[test]
    fn touch_on_hit_updates_lru_order() {
        let mut cache = PrefixCache::default();
        let a = tokens(16);
        let b: Vec<u32> = (100..116).collect();

        cache.insert(&hashes(&a));
        cache.insert(&hashes(&b));

        hit(&mut cache, &a);

        assert!(cache.evict_one());
        assert_eq!(hit(&mut cache, &a), 16);
        assert_eq!(hit(&mut cache, &b), 0);
    }

    #[test]
    fn bytes_used_tracks_block_count() {
        let mut cache = PrefixCache::default();
        assert_eq!(cache.bytes_used(16, 100), 0);

        cache.insert(&hashes(&tokens(16)));
        assert_eq!(cache.bytes_used(16, 100), 1600);

        cache.insert(&hashes(&tokens(32)));
        assert_eq!(cache.bytes_used(16, 100), 3200);
    }

    #[test]
    fn evict_returns_false_when_empty() {
        let mut cache = PrefixCache::default();
        assert!(!cache.evict_one());
    }

    #[test]
    fn partial_block_ignored() {
        let mut cache = PrefixCache::default();
        cache.insert(&hashes(&tokens(10)));
        assert_eq!(cache.bytes_used(16, 1), 0);
        assert_eq!(hit(&mut cache, &tokens(10)), 0);
    }

    #[test]
    fn lock_multi_block_prevents_parent_eviction() {
        let mut cache = PrefixCache::default();
        cache.insert(&hashes(&tokens(16)));
        cache.insert(&hashes(&tokens(32)));

        cache.lock(&hashes(&tokens(32)));
        assert!(!cache.evict_one());

        cache.unlock(&hashes(&tokens(32)));
        assert!(cache.evict_one());
        assert!(cache.evict_one());
        assert!(!cache.evict_one());
    }

    #[test]
    fn multi_block_prefix_eviction() {
        let mut cache = PrefixCache::default();
        cache.insert(&hashes(&tokens(16)));
        cache.insert(&hashes(&tokens(32)));
        cache.insert(&hashes(&tokens(48)));
        assert_eq!(cache.bytes_used(16, 1), 48);

        assert!(cache.evict_one());
        assert!(cache.evict_one());
        assert!(cache.evict_one());
        assert!(!cache.evict_one());
        assert_eq!(cache.bytes_used(16, 1), 0);
    }

    #[test]
    fn release_evicts_the_tail_and_preserves_a_reusable_prefix() {
        let mut cache = PrefixCache::default();
        let blocks = hashes(&tokens(48));
        cache.insert(&blocks);
        cache.lock(&blocks);
        cache.unlock(&blocks);
        assert!(cache.evict_one());
        assert_eq!(cache.bytes_used(16, 1), 32);
        assert_eq!(cache.longest_hit(&blocks), 2);
    }

    #[test]
    fn shared_blocks_stay_pinned_until_the_last_request_releases_them() {
        let mut cache = PrefixCache::default();
        let a = hashes(&tokens(32));
        let mut other = tokens(16);
        other.extend(100..116);
        let b = hashes(&other);
        cache.insert(&a);
        cache.insert(&b);
        cache.lock(&a);
        cache.lock(&b);
        cache.unlock(&a);
        assert!(cache.evict_one());
        assert_eq!(cache.longest_hit(&a), 1);
        assert_eq!(cache.longest_hit(&b), 2);
        assert!(!cache.evict_one());
        cache.unlock(&b);
        assert!(cache.evict_one());
        assert_eq!(cache.longest_hit(&b), 1);
        assert!(cache.evict_one());
        assert!(!cache.evict_one());
    }

    #[test]
    fn split_token_slices_preserve_the_original_block_hash() {
        let tokens = tokens(16);
        let mut expected = std::collections::hash_map::DefaultHasher::new();
        42_u64.hash(&mut expected);
        tokens.hash(&mut expected);
        for split in 0..=tokens.len() {
            assert_eq!(
                hash_block(42, &tokens[..split], &tokens[split..]),
                expected.finish()
            );
        }
    }
}
