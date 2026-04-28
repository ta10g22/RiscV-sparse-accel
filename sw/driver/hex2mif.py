import sys


def store_word(data, addr, word):
    data[addr + 0] = (word >> 0) & 0xFF
    data[addr + 1] = (word >> 8) & 0xFF
    data[addr + 2] = (word >> 16) & 0xFF
    data[addr + 3] = (word >> 24) & 0xFF


def parse_intel_hex(filename):
    data = {}
    base_addr = 0

    with open(filename, "r") as f:
        for line in f:
            line = line.strip()
            if not line or not line.startswith(":"):
                continue

            byte_count = int(line[1:3], 16)
            address = int(line[3:7], 16)
            record_type = int(line[7:9], 16)

            if record_type == 0:
                for i in range(byte_count):
                    data[base_addr + address + i] = int(line[9 + i * 2 : 11 + i * 2], 16)
            elif record_type == 2:
                base_addr = int(line[9:13], 16) << 4
            elif record_type == 4:
                base_addr = int(line[9:13], 16) << 16
            elif record_type == 1:
                break

    return data


def parse_raw_hex(filename):
    data = {}
    addr = 0

    with open(filename, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue

            if line.startswith("@"):
                addr = int(line[1:], 16) * 4
                continue

            try:
                store_word(data, addr, int(line, 16))
                addr += 4
            except ValueError:
                continue

    return data


def parse_verilog_hex(filename):
    data = {}
    addr = 0
    word_addressed = False

    with open(filename, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            if line.startswith("@"):
                addr = int(line[1:], 16)
                word_addressed = True
                continue

            tokens = line.split()
            if word_addressed and len(tokens) == 1 and len(tokens[0]) > 2:
                try:
                    store_word(data, addr * 4, int(tokens[0], 16))
                    addr += 1
                    continue
                except ValueError:
                    pass

            word_addressed = False
            for token in tokens:
                try:
                    data[addr] = int(token, 16)
                    addr += 1
                except ValueError:
                    continue

    return data


def bytes_to_words(data, depth):
    words = [0] * depth

    for addr, byte_val in data.items():
        word_addr = addr // 4
        byte_idx = addr % 4
        if word_addr < depth:
            words[word_addr] |= byte_val << (byte_idx * 8)

    return words


def write_mif(words, filename, width=32, byte_lane=None):
    depth = len(words)

    with open(filename, "w") as f:
        f.write(f"DEPTH = {depth};\n")
        f.write(f"WIDTH = {width};\n")
        f.write("ADDRESS_RADIX = HEX;\n")
        f.write("DATA_RADIX = HEX;\n\n")
        f.write("CONTENT BEGIN\n")

        if byte_lane is None:
            fmt_width = 8
            shift = 0
            mask = 0xFFFFFFFF
        else:
            fmt_width = 2
            shift = byte_lane * 8
            mask = 0xFF

        i = 0
        while i < depth:
            val = (words[i] >> shift) & mask
            if val != 0:
                f.write(f"  {i:04X} : {val:0{fmt_width}X};\n")
                i += 1
                continue

            j = i
            while j < depth and ((words[j] >> shift) & mask) == 0:
                j += 1

            if j - i > 1:
                f.write(f"  [{i:04X}..{j - 1:04X}] : {0:0{fmt_width}X};\n")
            else:
                f.write(f"  {i:04X} : {0:0{fmt_width}X};\n")
            i = j

        f.write("END;\n")


def main():
    if len(sys.argv) < 3:
        print("Usage: hex2mif.py input.hex output.mif [depth] [--split-bytes]")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]
    split_bytes = "--split-bytes" in sys.argv
    depth = 16384

    for arg in sys.argv[3:]:
        if not arg.startswith("--"):
            try:
                depth = int(arg)
            except ValueError:
                pass

    with open(input_file, "r") as f:
        first_line = f.readline().strip()

    if first_line.startswith(":"):
        print(f"Parsing Intel HEX: {input_file}")
        data = parse_intel_hex(input_file)
    elif first_line.startswith("@"):
        print(f"Parsing Verilog HEX: {input_file}")
        data = parse_verilog_hex(input_file)
    else:
        print(f"Parsing raw HEX: {input_file}")
        data = parse_raw_hex(input_file)

    words = bytes_to_words(data, depth)
    non_zero = sum(1 for word in words if word != 0)
    print(f"Loaded {non_zero} non-zero words")

    if split_bytes:
        base_name = output_file.rsplit(".", 1)[0]
        for lane in range(4):
            lane_file = f"{base_name}{lane}.mif"
            write_mif(words, lane_file, width=8, byte_lane=lane)
            print(f"Written: {lane_file} (byte lane {lane})")
    else:
        write_mif(words, output_file)
        print(f"Written: {output_file}")


if __name__ == "__main__":
    main()
