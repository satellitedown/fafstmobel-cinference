# fafstmobel: Cinference

A repository-local installer for [fafstmobel](https://huggingface.co/satellitedown/fafstmobel), using [Cinference](https://github.com/satellitedown/cinference). Adapted from [Fast Long Context — Cinference](https://github.com/satellitedown/fast-long-context-cinference), with this model's own validated **256K context, DFlash2-15, K8V4, and vision** profile.

## Run

You need **Linux x86_64, an RTX 5090 (32 GB), and NVIDIA drivers compatible with CUDA 13.4**. This preset builds for Blackwell **sm_120a**; other GPUs are not validated. The installer does not install or change GPU drivers.

Open a terminal in this repository and run:

```bash
bash setup.sh
```

The same three-option workflow handles installation and serving:

1. **Install everything (build + download):** check prerequisites, offer to install missing system build packages with permission, install local tools, build the pinned runtime, and download the model. Allow **~23.8 GB for model files**, plus software, build products, and download working space.
2. **Download / resume model:** download the pinned artifact and metadata without compiling the runtime or installing CUDA. Interrupted downloads retain their local cache and can be resumed. Existing files are checksum-verified rather than silently replaced.
3. **Start the server:** run in the foreground. Leave the terminal open while using the API; **Ctrl+C** stops it. Choose **0** to exit the menu.

An interrupted install can be continued with option 1; an interrupted download with option 2. Existing modified runtime source, unexpected CUDA files, or mismatched model files are reported instead of reset or deleted. Review the error and move conflicting files aside yourself before retrying.

By default, everything lives inside this checkout: `.tools/`, `.venv/`, `.cuda-toolkit/`, `runtime/ninfer/`, and `models/fafstmobel/`. The isolated CUDA SDK is pinned to **13.4.92**, with Release builds limited to two jobs; it does not depend on a separate model-building project or system CUDA toolkit. System compilers, NVIDIA driver libraries, FFmpeg development libraries, and libcurl >= 7.85 remain prerequisites.

## Connect an application

Use the OpenAI-compatible API at **`http://127.0.0.1:8001/v1`**, model **`fafstmobel-cinference`**. No API key is required. Keep the server on loopback: **there is no authentication**. Requests run one at a time.

The profile in [runtime-manifest.json](runtime-manifest.json) uses:

- context **262,144 tokens**, default maximum output **32,768 tokens**, within remaining context;
- **K8V4** KV cache, **DFlash2** speculation with 15 draft tokens and the bundled proposal head;
- vision enabled and thinking preserved;
- two host-state slots and **1,024 MiB** of host KV storage.

Verified on an RTX 5090: a **259,843-token prompt** recalled `MAPLE-8427` from its beginning; ordinary text, function-tool calls, and a red/blue image also completed successfully. This is a capacity and integration smoke check, not a quality or throughput benchmark.

The measured startup left approximately **700 MiB of VRAM free** with this desktop running. Other GPU workloads can prevent startup; stop them yourself before serving. To reserve more headroom, explicitly reduce context, for example `bash scripts/serve.sh --max-context 131072`. Configure the client to the same smaller limit. The server does not silently disable vision or speculation to fit.

For direct use after installation:

```bash
bash scripts/serve.sh
```

`MODEL_PATH` can select another compatible v3 artifact; `HOST` and `PORT` override the bind address. Additional native server arguments follow the manifest profile. `bash scripts/serve.sh --help`, `bash scripts/install.sh --help`, and `bash setup.sh --help` work without an installed runtime. For a different model storage location, the downloader accepts `--models-dir`; set `MODEL_PATH` when serving from that location.

## Oh My Pi (OMP)

Merge this provider into `~/.omp/agent/models.yml`, keeping existing providers:

```yaml
providers:
  fafstmobel:
    baseUrl: http://127.0.0.1:8001/v1
    auth: none
    api: openai-completions
    models:
      - id: fafstmobel-cinference
        name: fafstmobel 27B 256K (Cinference DFlash2 + Vision)
        contextWindow: 262144
        maxTokens: 32768
        tokenizer: qwen3
        reasoning: true
        thinking:
          mode: effort
          efforts: [low, medium, xhigh]
          defaultLevel: medium
          requiresEffort: false
        input: [text, image]
        imageInputDecoder: stb
        cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0}
        compat:
          supportsDeveloperRole: true
          supportsStore: false
          supportsStrictMode: false
          supportsToolChoice: false
          supportsReasoningEffort: true
          thinkingFormat: qwen-chat-template
          qwenTemplateReasoningEffort: true
          maxTokensField: max_tokens
```

Start the server first, then open OMP:

```bash
omp --model fafstmobel/fafstmobel-cinference
```

Use `--thinking off` for non-thinking requests. The explicit Qwen template setting is necessary because the custom model ID does not identify the upstream architecture to OMP. This registers a selectable model; it does not change your default model or start the server automatically.

## Verification

[results/verification.json](results/verification.json) records the runtime/model pins, active profile, and observed smoke-check responses. These checks do not substitute for evaluating model quality on your own workloads.

## Immutable downloads

[runtime-manifest.json](runtime-manifest.json) pins:

- runtime: `satellitedown/cinference` @ `b74044fb0a319cd2a737cb7108012e6344b96dac`;
- model: `satellitedown/fafstmobel` @ `54202e174c5f05945fbb873d1c2d8384e2643bd3`;
- all **13 published model files**, including licenses, notices, provenance, conversion records, and SHA-256 digests. The Hub-generated `.gitattributes` is not needed.

The model artifact is `models/fafstmobel/fafstmobel.ninfer`, **23,719,715,844 bytes**, SHA-256 `70752ce85422f9d716438f85e80e6b68c496197c41c2aed32b126f1c23ce7364`. Download verification also checks the artifact size and NInfer v3 header. Published conversion records retain historical build information; no historical build path is used by this installer.

## Model lineage — no training

fafstmobel applies the observed **Huihui minus Qwen** decoder-weight delta to **UkisAI Swift-Qwen3.8-27b**, rounds to BF16, quantizes the text model to NVFP4/FP8 using calibration data, and exports a NInfer v3 artifact. It is a delta transplant, not a newly fitted refusal direction or proof that all refusals are removed. Swift was not retrained and no new draft model was trained. This installer only downloads the completed artifact; it does not train, quantize, convert, or change weights.

The artifact includes **text, vision, MTP, and the pretrained z-lab DFlash2 draft** in one file. DFlash2 needs no separate draft download. Exact upstream revisions and transformation notices are retained in the downloaded `PROVENANCE.md` and `NOTICE`.

## Licensing and credits

The **installer code is Apache-2.0**, under [LICENSE](LICENSE). That license does **not** relicense downloaded weights or software.

The **Swift contribution is under the Swift Open License v1.0**, not unrestricted Apache-2.0. Its commercial-use grant is subject to the US$1 million gross-revenue threshold and related definitions in Section 5; commercial use by a legal entity exceeding the threshold requires a separate Swift Enterprise License. Read the complete downloaded `LICENSE.swift` before use or redistribution. Attribution, license-copy, and change-notice conditions also apply. Qwen, Huihui, and DFlash2 contributions retain their Apache-2.0 terms; NInfer/Cinference and CUDA retain their respective software licenses.

Credits include the original installer recipe, Cinference, Neroued/NInfer, Qwen/Alibaba Cloud, Huihui AI, UkisAI, z-lab, Dragoy, HuggingFaceH4, and the quantization-tool contributors. See [NOTICE](NOTICE) and the model's downloaded license/provenance files. This is an unofficial community recipe, not an upstream endorsement. Model outputs are unmoderated and are not suitable for safety-critical use.
