ARG PGVER
FROM postgres:$PGVER-alpine

RUN apk add --no-cache \
    make \
    gcc \
    musl-dev \
    postgresql-dev \
    git \
    clang \
    llvm

WORKDIR /home/postgres/spock

COPY . /home/postgres/spock/

#RUN USE_PGXS=1 make && USE_PGXS=1 make install

EXPOSE 5432

ENTRYPOINT ["docker-entrypoint.sh"]

CMD ["postgres"]
