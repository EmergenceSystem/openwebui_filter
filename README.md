# openwebui_filter

An [Emergence](https://github.com/EmergenceSystem) `em_filter` agent that connects to an [Open WebUI](https://openwebui.com) instance via its OpenAI-compatible chat API.

## Features

- Sends queries to any Open WebUI instance
- Maintains a rolling conversation history (last 5 exchanges) in ETS
- Survives worker restarts within the same BEAM session
- Fully configured via environment variables — no credentials in code

## Configuration

| Variable | Required | Default | Description |
|---|---|---|---|
| `OPENWEBUI_ENDPOINT` | yes | — | Base URL of the Open WebUI instance (no trailing slash) |
| `OPENWEBUI_API_KEY` | yes | — | Bearer token / API key |
| `OPENWEBUI_MODEL` | no | `Qwen/Qwen3-8B-AWQ` | Model name as it appears in Open WebUI |

## Usage

```bash
export OPENWEBUI_ENDPOINT="https://your-instance.example.com"
export OPENWEBUI_API_KEY="your-api-key"
export OPENWEBUI_MODEL="Qwen/Qwen3-8B-AWQ"  # optional

rebar3 shell
```

```erlang
application:ensure_all_started(openwebui_filter).

%% Single query
openwebui_filter_app:handle(<<"{\"value\": \"What is Erlang?\"}">>, #{}).

%% With conversation history (managed automatically via ETS memory)
```

The handler accepts a JSON body with a `value` or `query` field and returns an embryo list:

```json
{ "value": "Explain OTP supervisors" }
```

Response embryo:

```erlang
[#{<<"properties">> => #{<<"resume">> => <<"OTP supervisors are...">>}}]
```

## Capabilities

```erlang
[<<"search">>, <<"query">>, <<"openwebui">>, <<"llm">>,
 <<"summarize">>, <<"generate">>, <<"local_ai">>]
```

## Build

```bash
rebar3 compile
```

Requires Erlang/OTP 27+ (uses the `json` module from the standard library).
