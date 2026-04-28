import sys


def main():
    if len(sys.argv) < 3:
        print("Usage: bin2hex32.py input.bin output.hex")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]

    with open(input_file, "rb") as f:
        data = f.read()

    while len(data) % 4 != 0:
        data += b"\x00"

    with open(output_file, "w") as f:
        f.write("@00000000\n")
        for i in range(0, len(data), 4):
            word = (
                (data[i + 3] << 24)
                | (data[i + 2] << 16)
                | (data[i + 1] << 8)
                | data[i]
            )
            f.write(f"{word:08X}\n")

    print(f"Converted {len(data)} bytes ({len(data) // 4} words) to {output_file}")


if __name__ == "__main__":
    main()
