1 - Formate o cartão SD do dispositivo como FAT32
2 - Copie todos estes arquivos na raíz do cartão
3 - Instale o uboot:
	sudo dd if=u-boot-armbian.bin of=/dev/sdX bs=8k seek=1

4 - Acesse o dispositivo pelo nome: vpn-box.local
5 - Acesso ssh: root passwd = zaq12wsx
