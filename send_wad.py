import serial
import sys
import time

# Configuracion (ajustar puerto COM segun corresponda)
COM_PORT = 'COM3'
BAUD_RATE = 115200
WAD_FILE = 'doom1.wad'

def main():
    try:
        with open(WAD_FILE, 'rb') as f:
            wad_data = f.read()
    except FileNotFoundError:
        print(f"Error: No se encuentra el archivo {WAD_FILE}")
        print("Descarga la version shareware 'doom1.wad' y ponla en esta misma carpeta.")
        sys.exit(1)

    print(f"Archivo {WAD_FILE} cargado ({len(wad_data)} bytes).")
    
    try:
        # Timeout necesario por si el envio se bloquea
        ser = serial.Serial(COM_PORT, BAUD_RATE, timeout=1)
        print(f"Puerto {COM_PORT} abierto a {BAUD_RATE} baudios.")
    except serial.SerialException as e:
        print(f"Error al abrir el puerto {COM_PORT}: {e}")
        print("Asegurate de que el puerto es correcto y no esta en uso.")
        sys.exit(1)

    print("Iniciando transmision... (esto puede tardar unos 6 minutos)")
    
    start_time = time.time()
    
    # Escribimos los datos en bloques pequenos para que el buffer del OS
    # los despache de manera uniforme, aunque pyserial podria con todo de golpe.
    chunk_size = 4096
    bytes_sent = 0
    
    while bytes_sent < len(wad_data):
        end = min(bytes_sent + chunk_size, len(wad_data))
        chunk = wad_data[bytes_sent:end]
        ser.write(chunk)
        bytes_sent += len(chunk)
        
        # Muestra el progreso en la terminal
        progress = (bytes_sent / len(wad_data)) * 100
        print(f"\rEnviados: {bytes_sent} / {len(wad_data)} bytes ({progress:.1f}%)", end="")
        
    ser.close()
    elapsed = time.time() - start_time
    print(f"\n\nTransmision completada en {elapsed:.1f} segundos.")
    print("La pantalla de la FPGA deberia ponerse verde y mostrar DOOM en los displays.")

if __name__ == '__main__':
    main()
