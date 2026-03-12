# multi-arch: built for linux/amd64, linux/arm64, linux/arm/v7
FROM python:3-alpine
WORKDIR /app
COPY proxy.py .
EXPOSE 8080
CMD ["python3", "-u", "proxy.py"]
