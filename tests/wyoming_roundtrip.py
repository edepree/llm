"""Send a WAV file to a Wyoming ASR server and print the transcript.

Usage: uv run --no-project --with wyoming python -I tests/wyoming_roundtrip.py <host> <port> <wav>
Exits non-zero if the server lists no ASR model or returns no text within 30 s.
"""

import asyncio
import sys
import wave

from wyoming.asr import Transcribe, Transcript
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.client import AsyncTcpClient
from wyoming.info import Describe, Info

CHUNK_FRAMES = 1024


async def read_until(client: AsyncTcpClient, is_type):
    while True:
        event = await client.read_event()
        if event is None:
            raise ConnectionError("server closed the connection")
        if is_type(event.type):
            return event


async def main(host: str, port: int, wav_path: str) -> int:
    async with AsyncTcpClient(host, port) as client:
        await client.write_event(Describe().event())
        info = Info.from_event(await read_until(client, Info.is_type))
        models = [m.name for asr in info.asr for m in asr.models]
        print("ASR models:", models)
        if not models:
            return 1

        with wave.open(wav_path, "rb") as wav:
            rate, width, channels = wav.getframerate(), wav.getsampwidth(), wav.getnchannels()
            await client.write_event(Transcribe(name=models[0]).event())
            await client.write_event(AudioStart(rate=rate, width=width, channels=channels).event())
            while frames := wav.readframes(CHUNK_FRAMES):
                await client.write_event(
                    AudioChunk(rate=rate, width=width, channels=channels, audio=frames).event()
                )
            await client.write_event(AudioStop().event())

        transcript = Transcript.from_event(await read_until(client, Transcript.is_type))
        print("Transcript:", transcript.text)
        return 0 if transcript.text.strip() else 1


if __name__ == "__main__":
    host, port, wav_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    sys.exit(asyncio.run(asyncio.wait_for(main(host, port, wav_path), timeout=30)))
