FROM python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY pyproject.toml .
COPY src ./src
RUN --mount=type=secret,id=custom_ca,required=false \
    --mount=type=secret,id=pip_config,target=/etc/pip.conf,required=false \
    set -eu; \
    if [ -f /run/secrets/custom_ca ]; then \
      cp /run/secrets/custom_ca /usr/local/share/ca-certificates/build-ca.crt && update-ca-certificates; \
    fi; \
    pip install --no-cache-dir .; \
    rm -f /usr/local/share/ca-certificates/build-ca.crt
USER 65532:65532
EXPOSE 8000
CMD ["uvicorn", "voiceprompt.app:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
