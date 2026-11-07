# escape=`
# The escape directive moves line continuation to the backtick.
FROM mcr.microsoft.com/windows/servercore:ltsc2025@sha256:d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4 AS a
RUN curl.exe -o C:\tool.zip `
	https://example.com/tool.zip
FROM mcr.microsoft.com/windows/nanoserver:ltsc2025
