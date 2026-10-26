FROM --platform=$BUILDPLATFORM golang:1.24-bookworm AS voxgate
ARG VOXGATE_REVISION=da98bb5ff9ce913b4317081a00e9e0c51f080edf
ARG TARGETOS TARGETARCH
RUN git clone https://github.com/WEIFENG2333/voxgate.git /src
WORKDIR /src
RUN git checkout --detach ${VOXGATE_REVISION}
COPY voxgate-file-chunks.patch /tmp/file-chunks.patch
RUN git apply --check /tmp/file-chunks.patch && git apply /tmp/file-chunks.patch
COPY voxgate-empty-final.patch /tmp/empty-final.patch
RUN git apply --check /tmp/empty-final.patch && git apply /tmp/empty-final.patch
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -o /voxgate ./cmd/voxgate

FROM python:3.12-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home xinlika
WORKDIR /app
COPY requirements-heartball.lock /app/requirements-heartball.lock
RUN pip install --no-cache-dir -r requirements-heartball.lock
ARG INSTALL_AGENT_RUNTIME=false
RUN if [ "$INSTALL_AGENT_RUNTIME" = "true" ]; then pip install --no-cache-dir mcp==1.30.0 deepseek-harness-sdk==0.2.1rc2; fi
COPY --from=voxgate /voxgate /usr/local/bin/voxgate
COPY --from=voxgate /src/LICENSE /usr/share/doc/voxgate/LICENSE
COPY --chown=10001:10001 scripts /app/scripts
COPY --chown=10001:10001 prompts /app/prompts
COPY --chown=10001:10001 entrypoint.py /app/entrypoint.py
RUN mkdir -p /data /config && chown 10001:10001 /data /config
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 LANGSMITH_TRACING=false LANGCHAIN_TRACING_V2=false
USER 10001:10001
EXPOSE 18778
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD python -c "import socket,urllib.request; urllib.request.urlopen('http://'+socket.gethostbyname(socket.gethostname())+':18778/health',timeout=3)"
ENTRYPOINT ["python", "/app/entrypoint.py"]
