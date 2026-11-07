# Downloads with and without a checksum verification in the same instruction.
FROM scratch AS fetch
RUN curl -fsSL -o /tmp/a https://example.com/a \
	&& chmod +x /tmp/a
RUN wget -q https://example.com/b -O /tmp/b
RUN curl -fsSL https://example.com/install.sh | sh
ADD https://example.com/c.tar.gz /c.tar.gz
ADD --checksum=sha256:0000000000000000000000000000000000000000000000000000000000000000 https://example.com/d /d
ADD ["https://example.com/e", "/e"]
RUN ["curl", "-fsSLo", "/tmp/f", "https://example.com/f"]
RUN <<EOT
set -eu
wget -q -O /tmp/g https://example.com/g
EOT
RUN curl -fsSL -o /tmp/h https://example.com/h && sha256sum /tmp/h
RUN echo "result: $(curl -fsSL https://example.com/i)"
RUN apt-get install -y curl wget && echo "curl and wget are installed"
RUN curl -fsSL -o /tmp/j https://example.com/j \
	&& echo "$J_SHA512  /tmp/j" | sha512sum -c -
RUN fetch() { /usr/bin/curl -fsSL -o "$1" "$2" && echo "$3  $1" | sha256sum --check --strict -; } \
	&& fetch /tmp/k https://example.com/k "$K_SHA256"
RUN curl -fsSL -o /tmp/l https://example.com/l && shasum -a 256 -c /tmp/l.sha256
RUN ["/bin/sh", "-c", "curl -fsSL -o /tmp/m https://example.com/m"]
ONBUILD RUN curl -fsSL -o /tmp/n https://example.com/n
