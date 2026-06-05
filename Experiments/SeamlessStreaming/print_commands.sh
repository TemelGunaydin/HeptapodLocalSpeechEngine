#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
SeamlessStreaming local experiment commands

1. Clone the Hugging Face Space:

mkdir -p /tmp/heptapod-seamless
cd /tmp/heptapod-seamless
git clone https://huggingface.co/spaces/facebook/seamless-streaming
cd seamless-streaming

2. Backend:

cd /tmp/heptapod-seamless/seamless-streaming/seamless_server
conda create --yes --name smlss_server python=3.8 libsndfile==1.0.31
conda activate smlss_server
conda install --yes pytorch torchvision torchaudio pytorch-cuda=11.8 -c pytorch -c nvidia
pip install fairseq2 --pre --extra-index-url https://fair.pkg.atmeta.com/fairseq2/whl/nightly/pt2.1.1/cu118
pip install -r requirements.txt
uvicorn app_pubsub:app --reload --host localhost

3. Frontend in another terminal:

cd /tmp/heptapod-seamless/seamless-streaming/streaming-react-app
conda activate smlss_server
conda install -c conda-forge nodejs
npm install --global yarn
yarn
yarn build

Notes:
- CPU is not recommended for SeamlessStreaming.
- This is not yet the Swift HeptapodLiveSpeechDemo backend.
- Current native Heptapod low-latency text mode:

swift run HeptapodLiveSpeechDemo -- --real --system-audio --to tr --latency low --text-only --trace /tmp/heptapod-system-text.jsonl
EOF
