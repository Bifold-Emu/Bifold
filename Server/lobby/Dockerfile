FROM python:3.12-slim
RUN pip install --no-cache-dir "pyjwt[crypto]==2.9.0"
WORKDIR /app
COPY lobby.py .
ENV LOBBY_DATA_DIR=/data LOBBY_PORT=5000
VOLUME /data
EXPOSE 5000
CMD ["python3", "/app/lobby.py"]
