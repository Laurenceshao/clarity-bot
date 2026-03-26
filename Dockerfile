FROM python:3.13-slim

# Install bash, curl, jq — required by livex-config shell scripts
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["python", "bot.py"]
