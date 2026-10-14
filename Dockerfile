# bank-app/Dockerfile
#
# One image, two services: the bank app (uvicorn) and the traffic simulator.
# Self-contained: build from this directory.
#   docker build -t bank-app .
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    BANK_SCHEMA=bank \
    BANK_PORT=8090

WORKDIR /srv/bank

COPY requirements.txt /srv/bank/requirements.txt
RUN pip install --no-cache-dir -r /srv/bank/requirements.txt

COPY app /srv/bank/app
COPY traffic.py /srv/bank/traffic.py

RUN mkdir -p /srv/bank/out

EXPOSE 8090

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8090"]
