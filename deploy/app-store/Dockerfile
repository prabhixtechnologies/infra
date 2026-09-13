FROM public.ecr.aws/docker/library/python:3.12-alpine

WORKDIR /app
RUN apk add --no-cache wget \
  && pip install --no-cache-dir flask==3.0.3 boto3==1.35.36 gunicorn==23.0.0

COPY server.py /app/server.py
COPY www /srv/www

ENV STORE_WWW=/srv/www \
    STORE_ARTIFACTS=/artifacts \
    PORT=80 \
    PYTHONUNBUFFERED=1

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=5s \
  CMD wget -q -O /dev/null http://127.0.0.1/healthz || exit 1

CMD ["gunicorn", "-b", "0.0.0.0:80", "-w", "2", "--timeout", "120", "server:app"]
