# Third-party notices

| Component | Used for | Licence | Source |
|---|---|---|---|
| OpenThai 2.0 ASR Streaming (iApp Technology) | Thai speech recognition model, downloaded on first run | OpenMDW-1.1 (text in `ASR/LICENSE-MODEL-OpenMDW-1.1.txt`) | https://huggingface.co/iapp/OpenThai2.0-ASR-Streaming |
| NVIDIA Nemotron 3.5 ASR streaming 0.6B | base model of the above | OpenMDW-1.1 | named on the model card |
| NVIDIA NeMo | model runtime | Apache-2.0 | https://github.com/NVIDIA-NeMo/Speech |
| uv (Astral) | creates the isolated Python runtime during setup | Apache-2.0 / MIT | https://github.com/astral-sh/uv |
| PyTorch, FastAPI, Uvicorn and their dependencies | speech service | their respective licences | installed by `ASR/setup.sh` |

"Nemotron" is a trademark of NVIDIA Corporation, used only to name the base model. This project is not affiliated
with or endorsed by NVIDIA or iApp Technology.
