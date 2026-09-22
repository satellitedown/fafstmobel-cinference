# Fast Long Context: Cinference

**Huihui Qwen3.8-27B Abliterated NVFP4 on a single RTX 5090 (32 GB), with 256K context.**

A one-menu installer using [Cinference](https://github.com/satellitedown/cinference), **MTP-10 speculative decoding**, and **K8V4 KV cache**.

## Run

You need **Linux x86_64, an RTX 5090 (32 GB), and NVIDIA drivers compatible with CUDA 13.4**.

```bash
git clone https://github.com/satellitedown/fast-long-context-cinference.git
cd fast-long-context-cinference
bash setup.sh
```

### Launcher

![Cinference setup menu](assets/setup-menu.png)

1. Choose **1** to install everything, download the model, and prepare it automatically. Allow **43 GB for model files**, plus software.
2. Choose **3** to start the server. Leave the terminal open while using it.

Choose **2** to resume an interrupted download or preparation. **Ctrl+C** stops the server. Setup never starts it automatically or changes your NVIDIA driver.

## Connect to your favorite AI app

Start the server, then copy this into your AI app or coding harness:

> Use the OpenAI-compatible server at `http://127.0.0.1:8000/v1` with model `qwen3.8-27b-huihui-abliterated-cinference`. No API key is needed. Set context to 262,144 tokens and maximum output to 32,768, within the remaining context space.

Keep it on localhost: there is **no authentication**. One request runs at a time.

## Results

| Prompt tokens | Tokens/s |
|---:|---:|
| 8,192 | 450.78 |
| 32,768 | 432.60 |
| 131,072 | 364.84 |
| 260,000 | 299.64 |

Huihui Qwen3.8-27B Abliterated NVFP4. Generation speed on synthetic recall, thinking off. [Measurements](https://github.com/satellitedown/cinference/blob/main/results/rtx5090-archive-recall.json).

## Credits

Cinference, NInfer, Qwen, Huihui AI, and Barding-Defense. [Model](https://huggingface.co/Barding-Defense/Qwen3.8-27B-huihui-abliterated-NVFP4-NInfer) · [Settings](runtime-manifest.json) · [Attribution](NOTICE).
