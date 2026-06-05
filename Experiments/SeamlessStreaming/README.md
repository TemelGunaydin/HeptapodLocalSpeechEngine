# SeamlessStreaming Experiment

This is a research-only path for trying Meta SeamlessStreaming outside the Swift
pipeline. It is not a native `HeptapodLiveSpeechDemo` backend yet.

Meta's public instructions point to the Hugging Face Space for the runnable
streaming demo. The local demo is a Python/FastAPI backend launched with
`uvicorn` plus a separate React frontend.

## Clone The Space

```bash
mkdir -p /tmp/heptapod-seamless
cd /tmp/heptapod-seamless
git clone https://huggingface.co/spaces/facebook/seamless-streaming
cd seamless-streaming
```

## Backend

The official Space README recommends a conda environment. CPU is not recommended
for this model; expect high latency without a CUDA GPU.

```bash
cd /tmp/heptapod-seamless/seamless-streaming/seamless_server
conda create --yes --name smlss_server python=3.8 libsndfile==1.0.31
conda activate smlss_server
conda install --yes pytorch torchvision torchaudio pytorch-cuda=11.8 -c pytorch -c nvidia
pip install fairseq2 --pre --extra-index-url https://fair.pkg.atmeta.com/fairseq2/whl/nightly/pt2.1.1/cu118
pip install -r requirements.txt
uvicorn app_pubsub:app --reload --host localhost
```

For production-style local serving:

```bash
uvicorn app_pubsub:app --host 0.0.0.0
```

## Frontend

Run this in a second terminal:

```bash
cd /tmp/heptapod-seamless/seamless-streaming/streaming-react-app
conda activate smlss_server
conda install -c conda-forge nodejs
npm install --global yarn
yarn
yarn build
```

Then follow the Space's frontend/server instructions from that repository.

## Heptapod Integration Status

Current status in this repo:

- Catalog entry: `s2st.seamless_streaming.emma`
- Preset: `HeptapodModelCatalog.seamlessStreamingResearchPipeline`
- Native Swift adapter: not implemented
- Recommended Heptapod local mode today: `--text-only`

The next integration step is a local server bridge:

```text
Heptapod Swift audio chunks
  -> local SeamlessStreaming backend process/server
  -> partial text/speech events
  -> Heptapod trace + UI
```

