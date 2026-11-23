# Local model provenance

- Model: `iapp/OpenThai2.0-ASR-Streaming`
- Revision pinned for this prototype: `c28df2a70bb16376ed7dc6a5233cffb41bb54a68`
- Official model URI: https://huggingface.co/iapp/OpenThai2.0-ASR-Streaming
- Official iApp macOS guide: https://iapp.co.th/en/blog/openthai2p0-asr-streaming-how-to-run
- NeMo source pin specified by iApp: `cf724ac337d1ebc7d0dda1e23fb80916f52927a5`
- Files downloaded: the official `serve/` directory and `*_raw.nemo` only.
- Runtime: Apple Silicon CPU; `CHINDA_NUM_THREADS=1`; no CUDA, account token,
  paid API, or externally reachable listener.

The iApp guide records approximately 2.6 GB for the model and 1.4 GB for
packages on Mac, and recommends one CPU thread on an M3 Max. This case uses
`127.0.0.1:18081` rather than its default all-interface bind.
