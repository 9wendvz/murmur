## Benchmarks

Synthetic corpus: **3653 entries** (10 years, daily), 71924 words. Machine: 10-core Apple silicon, release build.

| operation | p50 | p95 |
| --- | ---: | ---: |
| save all entries (JSON encode, 679 KB) | 12 ms | 15 ms |
| load all entries (JSON decode) | 8.59 ms | 8.84 ms |
| insights, cold (sentiment for every entry) | 2551 ms | – |
| insights, warm (sentiment cached) | 458 ms | 479 ms |
| build search index, 1 core (11764 chunks × 512-d) | 54094 ms | – |
| build search index, 10 cores in parallel | 18917 ms | – |
| load saved index from disk (next launch) | 15 ms | 17 ms |
| re-index after editing one entry | 38 ms | – |
| similarity vs all chunks: Accelerate BLAS (sgemv) | 0.43 ms | 0.67 ms |
| similarity vs all chunks: plain Swift loop | 2.24 ms | 2.30 ms |
| **semantic search, end to end** (embed query + rank) | **18 ms** | 20 ms |
| keyword search (substring scan), for comparison | 6.82 ms | 8.05 ms |

Accelerate is **5.2×** faster than the plain loop for the similarity step. Parallel embedding builds the index **2.9×** faster; after that, launches load the saved index in 15 ms instead of re-embedding.

## Search quality

13 hand-labelled queries over 12 diary-style entries (queries mostly share no words with the right entry, e.g. *"times i felt lonely"* → *"spent the evening alone…"*).

| method | MRR | top-1 |
| --- | ---: | ---: |
| keyword match | 0.29 | 2/13 |
| **semantic (this app)** | **0.55** | **5/13** |
