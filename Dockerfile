# Backend only — monorepo root keeps ios/ and esp32/ out of the image via .dockerignore.
FROM python:3.12-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

COPY server/requirements.txt .
RUN pip install -r requirements.txt

COPY server/cardiac_mood ./cardiac_mood

EXPOSE 8080

# Railway injects PORT at runtime
CMD ["sh", "-c", "exec uvicorn cardiac_mood.main:app --host 0.0.0.0 --port \"${PORT:-8080}\""]
