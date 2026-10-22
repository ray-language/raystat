# raystat

Un agregador de métricas al estilo statsd, escrito en [raylang](https://github.com/ray-language/raylang).
Recibe líneas statsd por UDP y las sirve en el formato de Prometheus por HTTP. Lee con una fibra
por worker sobre el mismo socket, y cada una agrega en su propio estado sin cruzar hilos por cada
datagrama.

```
$ raystat serve
raystat 0.1.0: statsd on udp 127.0.0.1:8125, /metrics on http://127.0.0.1:9102, 11 receivers on 11 workers, receive buffer 8 MiB, flush every 10000 ms, window 60000 ms

$ printf 'api.requests:1|c|#method:get\napi.latency:12|ms' | nc -u -w0 127.0.0.1 8125
$ curl -s localhost:9102/metrics
# TYPE api_latency summary
api_latency{quantile="0.5"} 12
…
# TYPE api_requests_total counter
api_requests_total{method="get"} 1
```

```
raystat serve [--udp HOST:PORT] [--http HOST:PORT] [--flush 10s] [--window 1m] [--receivers N] [--recv-buffer 8M] [--quantiles 0.5,0.9,0.99]
raystat blast HOST:PORT [-n LINES] [-s SENDERS] [-b LINES_PER_DATAGRAM] [--series N] [--rate DATAGRAMS/S]
```

## Qué entiende

`nombre:valor|tipo[|@tasa][|#etiqueta:valor,…]`, varias líneas por datagrama:

| statsd | en Prometheus |
|---|---|
| `c` contador (con `@0.1`, cuenta ×10) | `nombre_total`, acumulado |
| `g` gauge; `+n`/`-n` lo mueven | `nombre`, el último valor (el más reciente entre receptoras gana) |
| `ms`, `h`, `d` temporizador o histograma | `summary`: cuantiles sobre la ventana (`--window`), y `_sum` y `_count` acumulados |
| `s` set | gauge: miembros distintos en la ventana |

Las etiquetas de DogStatsD se convierten en labels de Prometheus, ordenados. Los nombres se adaptan
a Prometheus (`my-app.http` → `my_app_http`). Las líneas mal formadas se cuentan en
`raystat_bad_lines_total`. raystat también publica sus propias métricas:

- `raystat_packets_total` y `raystat_lines_total`;
- `raystat_receiver_packets_total{receiver,worker}`: cuánto lee cada receptora y en qué worker;
- `raystat_merge_seconds` y `raystat_merge_seconds_max`;
- `raystat_series` y `raystat_flushes_total`.

## Cómo

```
src/main.ray     la línea de órdenes (serve, blast)
src/line.ray     el protocolo: separa líneas por octeto, parsea cada una
src/shard.ray    lo que junta una receptora entre flushes (temporizadores con muestreo de reservorio)
src/store.ray    la fusión de las receptoras, la ventana deslizante y el texto de Prometheus
src/server.ray   receptoras, coordinador y HTTP (net/webserver)
src/blast.ray    el generador de carga
```

- **Una receptora por worker, sobre el mismo socket.** `spawn` las reparte por los workers
  (`worker_id()` lo muestra) y el kernel reparte los datagramas entre ellas por igual. Cada una
  parsea y agrega en su propio estado, así que no hay mensajes entre hilos por datagrama.
- **El coordinador** pide a cada receptora su estado cada `--flush` (se lo entregan por un canal y
  empiezan uno vacío), lo fusiona y guarda la página ya renderizada. El handler HTTP solo pide esa
  página.
- **Las receptoras miran su canal de control** entre datagramas, o cada 50 ms si no llega nada
  (el plazo de lectura del socket).
- **Un búfer de recepción grande** (`--recv-buffer`, 8 MiB por defecto, con
  `net.set_recv_buffer`): una ráfaga que llega más rápido de lo que se lee espera ahí en vez de
  perderse en el kernel. El SO lo recorta a su máximo (`kern.ipc.maxsockbuf` en macOS,
  `net.core.rmem_max` en Linux); el arranque dice cuánto puso.
- **Memoria acotada**: cada temporizador guarda 4096 muestras por receptora y flush (reservorio),
  y 1024 por flush en la ventana. El mínimo y el máximo exactos se conservan.

## Rendimiento

`make bench` (scripts/bench.sh) en un MacBook (Apple Silicon, 10 núcleos), binario nativo de raylang
1.27.76. Son 4 emisores de 10 líneas por datagrama desde otro proceso, 2 M de líneas en total:

| receptoras | 5000 dgram/s por emisor (200 k líneas/s) | 20 000 (800 k líneas/s) | sin freno (~2–3 M líneas/s) |
|---:|---:|---:|---:|
| 1 | 0 % perdido | 0–1 % | 65 % |
| 2 | 0 % | 0 % | 30 % |
| 4 | 0 % | 0 % | 11 % |
| 10 | 0 % | 0 % | 0 % (1,85 M líneas/s, todas recibidas) |

Una receptora a 20 000 datagramas/s está en el límite: de cuatro pasadas, dos perdieron el 1 %. Con
el búfer por defecto del sistema (`--recv-buffer 0`, 768 KiB en macOS) se perdían el 10 % con una
receptora a ese ritmo, y sin freno el 77, 43, 29 y 7 % (medido con raylang 1.27.65). Con la carga sin
freno, cada receptora más recupera tráfico: el reparto por workers escala, y el búfer absorbe el resto.

La fusión de cada flush cuesta según el número de series, no según el tráfico (`SERIES=N make
bench`, con 10 receptoras): 0,1–0,5 ms con 100 series, 17–26 ms con 10 000, y 90–300 ms con 100 000.
Con raylang 1.27.65 las cifras eran las mismas, salvo la de 100 series (1 ms).

## Uso

```bash
make build         # ./raystat, binario nativo
make test          # 12 tests en la VM (el de punta a punta: UDP, HTTP y parada)
make test-native   # los mismos, compilados
make run           # raystat serve en los puertos de siempre
make bench         # pérdida y rendimiento por número de receptoras (SERIES=N)
```

## Estado

| Qué | Estado |
|---|---|
| Protocolo, fusión, ventana, página, servicio | **12 tests** en VM y nativo (raylang 1.27.76, net 0.10.1) |
| De punta a punta | UDP de entrada, `/metrics` por HTTP, 5000 líneas del generador sin pérdida, parada limpia |
| Windows x86_64 | en CI, VM y nativo, con el test de punta a punta entero. Hasta raylang 1.27.73 el servidor se colgaba en nativo (#222) y en la VM se perdía el 30 % de la ráfaga del test (#208) |
| Windows arm64 | compila en nativo desde 1.27.73 (#197), con un hilo por tarea |

Pendiente: histogramas de Prometheus con buckets configurables, persistir los contadores entre
reinicios, y TCP como entrada.

## Hallazgos de dogfood

En `findings/` del directorio de las apps (`closed/2026-10/raystat-1.27.65.md`, y la re-medición
en `open/raystat-1.27.73.md`). Los tres quedaron arreglados en raylang 1.27.73:

1. **#207 [B]** ✅ En nativo, un plazo de lectura puesto con `net.set_read_timeout` por una fibra no
   valía para `recv_from` en otra fibra: esperaba para siempre. Dejó `/metrics` sin responder hasta
   que cada receptora se puso el plazo ella misma. Ahora es del socket, como dice la doc.
2. **#222 [B]** ✅ En Windows x86_64 nativo, una fibra en `net.tcp_accept` bloqueaba el hilo de su
   worker: el servidor HTTP dejaba parado un worker entero. Encontrado porque el CI se quedaba
   colgado; el test se saltaba ahí.
3. **#208 [E]** ✅ `net/udp` no dejaba agrandar el búfer de recepción (`SO_RCVBUF`), y las ráfagas se
   perdían en el kernel. Ahora está `net.set_recv_buffer`, y raystat pide 8 MiB.

Además, `spawn_local` y `spawn_isolated` no hicieron falta. Cada receptora hace todo su trabajo en
su fibra, y `spawn` ya las reparte por los workers.

Lo que salió bien:

- `net/udp` con varias fibras leyendo el mismo socket;
- `select_timeout` como reloj del coordinador;
- `serve_options_on` con un listener abierto en el puerto 0 para el test;
- los tipos de los estados (`Map` de tuplas, enums con canales) copiados por canal entre workers.
