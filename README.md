# Alpine Linux Diskless + WireGuard + Kernel Armbian

## Visão Geral

Solução de VPN mesh de baixo custo para interligar redes remotas atrás de CGNAT,
usando Alpine Linux em modo diskless em hardware ARM de baixo consumo.

### Hardware recomendado

| Dispositivo | CPU | RAM | Cartão |
|---|---|---|---|
| Orange Pi PC | Allwinner H3 (armv7) | 512MB | 2GB+ |
| Orange Pi Zero | Allwinner H2 (armv7) | 256MB | 2GB |

Custo aproximado: R$ 50-100 por unidade.

---

## Por que esta solução?

- Funciona atrás de CGNAT sem IP fixo no local remoto
- Não precisa de acesso ao roteador principal da rede
- Alpine diskless é resistente a quedas de energia (root em RAM)
- Um único IP fixo centraliza o acesso a múltiplos locais
- Hardware de R$50-100 substitui equipamentos proprietários caros

---

## Arquitetura

```
IP Fixo (MikroTik ou VPS)
WireGuard Server
              |
    +---------+---------+---------+
    |         |         |         |
Alpine 1   Alpine 2   Alpine 3   Alpine N
10.10.10.2 10.10.10.3 10.10.10.4 10.10.10.X
192.168.3  192.168.5  192.168.X  192.168.X
(CGNAT)    (CGNAT)    (CGNAT)    (CGNAT)
```

Cada Alpine é instalado na rede local do cliente e conecta de volta ao MikroTik
central via WireGuard. Por redirecionamento de porta, qualquer dispositivo de
qualquer rede remota fica acessível através do Alpine local.

---

## Topologia de Exemplo

```
Rede Principal:
MikroTik (IP Público / DDNS)
LAN: 192.168.10.0/24

Alpine 1 (site A):
VPN: 10.10.10.2
LAN: 192.168.3.0/24 (atrás de CGNAT)

Alpine 2 (site B):
VPN: 10.10.10.3
LAN: 192.168.5.0/24 (atrás de CGNAT)
```

---

## Como o Diskless Funciona

```
U-Boot -> extlinux.conf -> kernel + initramfs
                               |
                    monta modloop (squashfs, RO) em /.modloop
                    /lib/modules -> /.modloop (symlink)
                    root montado em tmpfs (RAM)
                    apkovl carregado de /media/mmcblk0p1/
                               |
                    sistema pronto em RAM
```

Alterações sobrevivem ao reboot apenas se salvas com:

```sh
lbu commit -d
```

O estado é salvo em: `/media/mmcblk0p1/hostname.apkovl.tar.gz`

---

## Preparação do Cartão SD

### 1. Gravar a imagem Alpine no cartão

```sh
# No PC
dd if=alpine-uboot-3.23.4-armv7.img of=/dev/sdX bs=4M status=progress
sync
```

A imagem inclui U-Boot para Orange Pi PC e Zero em:
- `/media/mmcblk0p1/u-boot/orangepi_pc/u-boot-sunxi-with-spl.bin`
- `/media/mmcblk0p1/u-boot/orangepi_zero/u-boot-sunxi-with-spl.bin`

### 2. Primeiro boot — setup-alpine

```
Which disk(s) would you like to use? [none]: none
```

Responder `none` — o sistema já está no cartão, não formatar nada.
Configurar: hostname, rede, timezone, senha root, SSH.

---

## Script de Instalação do Kernel Armbian

O script `install.sh` automatiza toda a configuração.

### Uso

```sh
./install.sh <ip-do-orange-pi>
```

### Estrutura de arquivos necessária

```
./
├── install.sh
├── output/
│   ├── vmlinuz-6.18.24-current-sunxi
│   ├── dtbs/
│   └── lib/modules/6.18.24-current-sunxi/
└── u-boot/
    └── u-boot-armbian.bin
```

### O que o script faz

1. Copia kernel, U-Boot e DTBs para a partição boot
2. Copia módulos do Armbian para o tmpfs
3. Gera o modloop (squashfs com os módulos)
4. Gera o initramfs com suporte a overlayfs/squashfs
5. Restaura o symlink `/lib/modules -> /.modloop`
6. Atualiza o `extlinux.conf`
7. Configura carregamento de módulos extras via `local.d`
8. Configura `lbu`, `fstab` e cache do apk
9. Salva o estado com `lbu commit -d`
10. Grava o U-Boot do Armbian

### Observações importantes

- O `mkinitfs` deve rodar ANTES de restaurar o symlink `/lib/modules`
- O modloop é gerado com `mksquashfs` a partir dos módulos no tmpfs
- O `lbu commit -d` persiste toda a configuração antes do reboot
- Pacotes instalados após o script precisam de `lbu commit -d` para persistir

---

## Módulos Extras

O módulo `sun8i_thermal` (sensor de temperatura do H3/H2) não carrega automaticamente.
O script cria `/etc/local.d/modules.start`:

```sh
#!/bin/sh
ln -sf /.modloop /lib/modules
modprobe sun8i_thermal
```

Verificar o sensor:

```sh
cat /sys/class/thermal/thermal_zone0/temp
```

---

## Persistência de Pacotes APK

```sh
setup-apkcache /media/mmcblk0p1/cache
apk add <pacote>
lbu commit -d
```

---

## Configuração do WireGuard

### Instalar

```sh
apk add wireguard-tools
lbu commit -d
```

### Gerar chaves

```sh
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
wg genkey | tee /etc/wireguard/private.key
cat /etc/wireguard/private.key | wg pubkey | tee /etc/wireguard/public.key
```

### /etc/wireguard/wg0.conf

```ini
[Interface]
PrivateKey = CHAVE_PRIVADA_ALPINE
Address = 10.10.10.2/24
MTU = 1380
PostUp = /etc/wireguard/firewall.start

[Peer]
PublicKey = CHAVE_PUBLICA_MIKROTIK
Endpoint = seu-ddns.exemplo.com:13231
AllowedIPs = 192.168.10.0/24,10.10.10.1/32
PersistentKeepalive = 25
```

Para acessar a rede local de outro Alpine, adicionar a rede dele nos AllowedIPs:

```ini
AllowedIPs = 192.168.10.0/24,10.10.10.1/32,192.168.3.0/24
```

---

## MTU e o Problema do Túnel via IPv6

**Sintoma:** ping funciona normalmente através do túnel, mas conexões TCP
(SSH, HTTP) travam ou nunca completam — especificamente quando o endpoint
WireGuard conecta por **IPv6** em vez de IPv4. A mesma configuração de
iptables funciona perfeitamente quando a conexão é por IPv4.

### Causa

O overhead de encapsulamento do WireGuard muda conforme o transporte externo:

```
Overhead IPv4 externo: ~60 bytes (20 IPv4 + 8 UDP + 32 WireGuard)
Overhead IPv6 externo: ~80 bytes (40 IPv6 + 8 UDP + 32 WireGuard)
```

O cabeçalho IPv6 é 20 bytes maior que o IPv4. Um MTU calculado pensando em
IPv4 (`1420`, o valor padrão comum) fica sem margem quando o túnel na
prática viaja por IPv6 — pacotes grandes (handshake TCP, dados de sessão)
ultrapassam o MTU real e precisam ser fragmentados.

O IPv6 não permite fragmentação no meio do caminho (só na origem) — depende
de ICMPv6 "Packet Too Big" para o PMTU Discovery funcionar. Se qualquer
ponto do caminho bloquear ICMPv6 (comum em CGNAT IPv6), os pacotes grandes
são descartados silenciosamente — o clássico "PMTUD black hole".

Ping (ICMP) usa pacotes pequenos e não é afetado. SSH/TCP usa pacotes
maiores durante o handshake e é onde o problema aparece.

### Diagnóstico

```sh
# Ver o MTU atual do wg0
ip link show wg0

# Testar o path MTU real
ping -M do -s 1400 <ip-do-peer-remoto>
# Reduzir o -s até parar de falhar/fragmentar
```

### Solução

Reduzir o MTU do WireGuard para ter margem mesmo no pior caso (IPv6):

```ini
MTU = 1380
```

```sh
wg-quick down wg0
wg-quick up wg0
```

### Impacto

MTU menor gera ligeiramente mais pacotes para a mesma quantidade de dados
(~3% de overhead adicional). Throughput e latência praticamente não são
afetados no uso típico (gerenciamento remoto, câmeras, acesso administrativo).
A troca vale a pena: um link "3% mais lento mas confiável" é sempre melhor
que um link que trava aleatoriamente em conexões TCP — especialmente em
hardware que não pode ser visitado fisicamente.

### /etc/wireguard/firewall.start

O script começa com um flush (`-F`) das chains para garantir estado conhecido —
idempotente mesmo se o PostUp rodar duas vezes numa reconexão. A função `pforward`
encapsula as três regras de cada redirecionamento (DNAT + FORWARD + MASQUERADE).

```sh
#!/bin/sh

LAN_IF="eth0"
WG_IF="wg0"

# Limpeza idempotente + base
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING
iptables -t mangle -F FORWARD
iptables -F FORWARD

# MSS clamping — evita fragmentação no túnel (sintoma "conecta mas trava")
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# NAT e forwarding base
iptables -t nat -A POSTROUTING -o $LAN_IF -j MASQUERADE
iptables -A FORWARD -i $WG_IF -o $LAN_IF -j ACCEPT
iptables -A FORWARD -i $LAN_IF -o $WG_IF -m state --state RELATED,ESTABLISHED -j ACCEPT

# pforward [dest_ip] [protocol] [port_in] [port_out]
pforward() {
    local dest=$1
    local prot=$2
    local pin=$3
    local pout=$4
    iptables -t nat -A PREROUTING -p $prot --dport $pin -j DNAT --to-destination $dest:$pout
    iptables -A FORWARD -p $prot -d $dest --dport $pout -j ACCEPT
    iptables -t nat -A POSTROUTING -d $dest -p $prot --dport $pout -j MASQUERADE
}

# === Configuração do site — editar conforme necessário ===
pforward 192.168.3.21 tcp 8080 80
ip route replace 192.168.3.21/32 via 10.10.10.2

# Confirmação visual no log do boot
echo "=== firewall.start aplicado ==="
iptables -L FORWARD -n -v
echo "=== NAT ==="
iptables -t nat -L -n -v
```

Pontos-chave de robustez para hardware remoto:

- **Flush no início** — estado conhecido a cada execução, sem acúmulo de regras duplicadas
- **MSS clamping antes do FORWARD** — a ordem importa; previne fragmentação
- **`ip route replace`** — idempotente, nunca falha por rota duplicada
- **`LAN_IF`/`WG_IF` no topo** — se a interface mudar de nome, corrige num lugar só
- **Log no final** — permite diagnóstico remoto via log do boot, sem ir ao local

Como o script faz flush das chains, ele assume que **só ele gerencia o iptables**.
Se houver outras regras (fail2ban, proteção de SSH), elas seriam apagadas.

> **Atenção:** a interface LAN no Alpine é `eth0`. Não confundir com `end0`
> (nome usado por algumas distros/kernels) — usar o nome errado faz a regra
> não casar com nenhum tráfego.

Como o flush no início já garante estado limpo, o `firewall.stop` é opcional —
o WireGuard ao descer remove a interface `wg0` e as regras associadas perdem efeito.
Ainda assim, um `firewall.stop` explícito é útil para reset manual durante
manutenção remota.

### /etc/wireguard/firewall.stop

```sh
#!/bin/sh
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -t raw -F
iptables -X
iptables -t nat -X
iptables -t mangle -X
iptables -t raw -X
iptables -Z
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
```

As policies `ACCEPT` no final garantem que, mesmo se alguma chain tiver sido
deixada em `DROP`, o reset volta ao estado permissivo — evitando ficar trancado
para fora de um equipamento remoto.

```sh
chmod +x /etc/wireguard/firewall.start
chmod +x /etc/wireguard/firewall.stop
lbu commit -d
```

### Subir no boot via local.d

O serviço `wg-quick` do OpenRC não funciona no Alpine diskless por dependência
de `need net` não satisfeita. O `local.d` é a solução confiável:

```sh
cat > /etc/local.d/wireguard.start << 'EOF'
#!/bin/sh
wg-quick up wg0
EOF

chmod +x /etc/local.d/wireguard.start
lbu commit -d
```

### IP Forwarding

```sh
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf
lbu commit -d
```

---

## LED de Status do WireGuard

O Orange Pi PC tem um LED vermelho (`orangepi:red:status`) que pode servir como
indicador visual do túnel — útil para diagnóstico em campo sem precisar de SSH.

Usando o trigger `netdev` do kernel, o LED pisca conforme tráfego na interface `wg0`.
Como o `PersistentKeepalive = 25` gera um pacote a cada 25 segundos, o LED pisca
nesse ritmo naturalmente:

- **LED piscando** → túnel ativo (keepalive + tráfego)
- **LED parado** → túnel caído

Não precisa de script de monitoramento — o kernel cuida de tudo via trigger.

### Carregar o módulo (em /etc/local.d/modules.start)

```sh
modprobe ledtrig-netdev
```

### Configurar o LED (no firewall.start, reaproveitando WG_IF)

```sh
LED=/sys/class/leds/orangepi:red:status
echo netdev > $LED/trigger
echo $WG_IF > $LED/device_name
echo 1 > $LED/tx
echo 1 > $LED/rx
```

Colocar o `modprobe` junto dos outros módulos e a config do LED no `firewall.start`
mantém a coerência (cada coisa no seu lugar) e reaproveita a variável `WG_IF` —
se o nome da interface mudar no futuro, corrige num lugar só.

---

## Configuração do MikroTik

```routeros
# Interface WireGuard
/interface wireguard
add name=wg0 listen-port=13231

# Endereço
/ip address
add address=10.10.10.1/24 interface=wg0

# Peer Alpine 1
/interface wireguard peers
add interface=wg0 \
    public-key="CHAVE_PUBLICA_ALPINE1" \
    allowed-address=10.10.10.2/32,192.168.3.0/24

# Peer Alpine 2
/interface wireguard peers
add interface=wg0 \
    public-key="CHAVE_PUBLICA_ALPINE2" \
    allowed-address=10.10.10.3/32,192.168.5.0/24

# Rotas para redes remotas
/ip route
add dst-address=192.168.3.0/24 gateway=10.10.10.2
add dst-address=192.168.5.0/24 gateway=10.10.10.3

# Firewall
/ip firewall filter
add chain=input protocol=udp dst-port=13231 action=accept comment="WireGuard"
```

---

## Acesso Entre Sites

Para que Alpine 2 enxergue a rede local do Alpine 1:

**wg0.conf do Alpine 2** — adicionar rede do Alpine 1 nos AllowedIPs:
```ini
AllowedIPs = 192.168.10.0/24,10.10.10.1/32,192.168.3.0/24
```

**MikroTik** — adicionar rede do Alpine 1 no allowed-address do peer Alpine 2:
```routeros
/interface wireguard peers
set [find public-key="CHAVE_PUBLICA_ALPINE2"] \
    allowed-address=10.10.10.3/32,192.168.5.0/24,192.168.3.0/24
```

---

## Redirecionamento de Portas

O Alpine não precisa ser o gateway da rede local. Via DNAT, qualquer dispositivo
da rede local acessa equipamentos de redes remotas através do Alpine:

```
Host 192.168.5.x : porta local
        |
   Alpine (DNAT)
        |
   wg0 (túnel VPN)
        |
   dispositivo remoto : porta destino
```

O `POSTROUTING -j MASQUERADE` sem especificar interface cobre todos os
redirecionamentos de uma vez, independente de qual interface o pacote usa para sair.

---

## Acesso Reverso: Internet → Dispositivo na Rede Remota

Cenário inverso: expor um dispositivo que está atrás do Alpine (rede remota via VPN)
para acesso direto pela internet, através do IP fixo do MikroTik.

```
Cliente na Internet
        |
   IP fixo do MikroTik : porta externa
        |
   dst-nat -> WG-Server (túnel VPN)
        |
   Alpine (rede 192.168.3.0/24)
        |
   dispositivo final : 192.168.3.84:80
```

### Configuração no MikroTik

```routeros
# 1. dst-nat: redireciona porta externa para o dispositivo via VPN
/ip firewall nat
add chain=dstnat action=dst-nat in-interface=WAN protocol=tcp \
    dst-port=82 to-addresses=192.168.3.84 to-ports=80

# 2. CRÍTICO: masquerade na saída pela interface WireGuard
/ip firewall nat
add chain=srcnat action=masquerade out-interface=WG-Server place-before=1
```

### Por que a regra de masquerade na VPN é necessária

Sem o masquerade na interface WireGuard, o pacote chega no dispositivo final
(`192.168.3.84`) com a origem do IP do cliente externo. O dispositivo tenta responder
para esse IP, mas a resposta vai para o gateway padrão da rede local (roteador
genérico), não para o Alpine — e a conexão nunca fecha. O ping funciona (ICMP é
mais simples), mas TCP/HTTP travam.

Com o masquerade na `WG-Server`, o MikroTik reescreve a origem para o próprio IP
na VPN (ex: `172.16.1.1`). O dispositivo final responde para o Alpine, que devolve
pela VPN ao MikroTik, fechando o caminho corretamente.

### Detalhe importante: masquerade genérico vs específico

```routeros
# Genérico — mascara saída por TODAS as interfaces (funciona em qualquer cenário)
chain=srcnat action=masquerade

# Específico — mascara só saída pela WAN (precisa regra extra para a VPN)
chain=srcnat action=masquerade out-interface=WAN
```

Se o MikroTik usa masquerade **genérico** (sem `out-interface`), o acesso reverso
pela VPN funciona automaticamente — a regra abrangente já cobre a `WG-Server`.

Se usa masquerade **específico por WAN**, é obrigatório adicionar a regra explícita
de masquerade `out-interface=WG-Server`, senão o tráfego da VPN não é mascarado e
o retorno quebra.

> Confirmar o nome real da interface WireGuard no MikroTik antes de criar a regra:
> `/interface wireguard print`. O nome pode não ser `wg0` (ex: `WG-Server`).

### Checklist para novos deployments

Se a sua prática padrão é usar masquerade **específico por WAN**
(`out-interface=WAN`), lembre-se: **todo novo MikroTik que precisar de acesso
reverso via VPN exige a regra explícita de masquerade na interface WireGuard.**

```routeros
/ip firewall nat add chain=srcnat action=masquerade out-interface=WG-Server place-before=1
```

Sem ela, o sintoma é traiçoeiro: o dispositivo responde ao ping (de dentro da LAN
do MikroTik e da VPN), mas o acesso reverso pela internet trava no handshake TCP.
É fácil culpar o equipamento — mas a causa é sempre a config. Um MikroTik com
masquerade genérico (sem `out-interface`) mascara essa necessidade e funciona
"por acidente"; ao padronizar para masquerade específico, a regra da VPN passa a
ser obrigatória em cada site.

---

## Verificação

```sh
# Kernel
uname -r

# Modo diskless confirmado
mount | grep -E 'tmpfs|modloop'
# esperado: tmpfs on / e /.modloop squashfs

# WireGuard
wg show

# Regras de firewall
iptables -t nat -L -n -v
iptables -L FORWARD -n -v

# Sensor de temperatura
cat /sys/class/thermal/thermal_zone0/temp

# Testar acesso a rede remota
ping 10.10.10.2
ping 192.168.3.21
```

---

## Referência Rápida

| Aspecto | Detalhe |
|---|---|
| Arquitetura | armv7 (Allwinner H2/H3) |
| Alpine | 3.23.x |
| Kernel | 6.18.24-current-sunxi (Armbian) |
| Interface LAN | eth0 |
| Partição boot | mmcblk0p1 (FAT32) |
| Root | tmpfs (RAM) |
| Módulos | /.modloop (squashfs, RO) |
| Estado persistido | /media/mmcblk0p1/hostname.apkovl.tar.gz |
| WireGuard porta | UDP 13231 |
| WireGuard MTU | 1380 (margem para túnel via IPv6) |
| Hardware mínimo | Orange Pi Zero — H2, 256MB RAM, cartão 2GB |
