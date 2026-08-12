import argparse
import sys
import os

def get_next_filename(base_name):
    """
    If base_name exists, append _2, _3, ... before the extension.
    Example: sorted_hostfile_1.txt -> sorted_hostfile_2.txt
    """
    if not os.path.exists(base_name):
        return base_name

    name, ext = os.path.splitext(base_name)
    i = 2
    while True:
        new_name = f"{name.rsplit('_', 1)[0]}_{i}{ext}"
        if not os.path.exists(new_name):
            return new_name
        i += 1

def sort_file(infile, outfile):
    outfile = get_next_filename(outfile)
    with open(infile, 'r') as f:
        lines = f.readlines()
    lines = sorted([line.strip() for line in lines if line.strip()])
    with open(outfile, 'w') as f:
        f.write("\n".join(lines) + "\n")
    print(f"Sorted file written to {outfile}")

def filter_file(infile, filterfile, outfile="filtered_file_1.txt"):
    outfile = get_next_filename(outfile)
    with open(infile, 'r') as f:
        lines = set(line.strip() for line in f if line.strip())
    with open(filterfile, 'r') as ff:
        filters = set(line.strip() for line in ff if line.strip())
    filtered_lines = lines - filters
    with open(outfile, 'w') as f:
        f.write("\n".join(sorted(filtered_lines)) + "\n")
    print(f"Filtered file written to {outfile}")

def main():
    parser = argparse.ArgumentParser(description="Sort or filter a file without modifying the original.")
    parser.add_argument("infile", help="Input file to process")
    parser.add_argument("--sort", action="store_true", help="Sort the input file")
    parser.add_argument("--outfile", help="Output file name. Defaults: sorted_hostfile_1.txt for sort, filtered_file_1.txt for filter")
    parser.add_argument("--filter", help="Filter file (removes lines present in filter file)")

    args = parser.parse_args()

    if args.sort:
        outfile = args.outfile if args.outfile else "sorted_hostfile_1.txt"
        sort_file(args.infile, outfile)
    elif args.filter:
        outfile = args.outfile if args.outfile else "filtered_file_1.txt"
        filter_file(args.infile, args.filter, outfile)
    else:
        print("Error: You must specify either --sort or --filter", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()