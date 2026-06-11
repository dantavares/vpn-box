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
PostUp = /etc/wireguard/firewall.start
PreDown = /etc/wireguard/firewall.stop

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

### /etc/wireguard/firewall.start

```sh
#!/bin/sh

# MASQUERADE global — cobre todos os redirecionamentos
iptables -t nat -A POSTROUTING -j MASQUERADE
iptables -A FORWARD -j ACCEPT

# Redirecionamentos de porta — adicionar conforme necessário
# Exemplo: porta 8080 local -> 192.168.3.21:80
iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 192.168.3.21:80

# Exemplo: mesma porta
iptables -t nat -A PREROUTING -p tcp --dport 8000 -j DNAT --to-destination 192.168.3.21

# Mostra regras aplicadas (útil para debug)
iptables -L -n -v
```

### /etc/wireguard/firewall.stop

```sh
#!/bin/sh

# Remover MASQUERADE e FORWARD
iptables -t nat -D POSTROUTING -j MASQUERADE
iptables -D FORWARD -j ACCEPT

# Remover redirecionamentos
iptables -t nat -D PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 192.168.3.21:80
iptables -t nat -D PREROUTING -p tcp --dport 8000 -j DNAT --to-destination 192.168.3.21
```

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
| Hardware mínimo | Orange Pi Zero — H2, 256MB RAM, cartão 2GB |
