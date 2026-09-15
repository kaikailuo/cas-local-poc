FROM python:3.13-alpine@sha256:7415fbc3c9e4979cc717d92377ab2bc7b2b4a2af1ac03cc52b5f3f88efedaf3a

WORKDIR /app
COPY app.py /app/app.py

EXPOSE 8081
ENTRYPOINT ["python", "/app/app.py"]
