#include "needle.h"

#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

static std::string read_file(const char* path) {
    std::ifstream input(path);
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

static std::vector<unsigned char> read_bytes(const char* path) {
    std::ifstream input(path, std::ios::binary);
    return std::vector<unsigned char>(
        std::istreambuf_iterator<char>(input),
        std::istreambuf_iterator<char>()
    );
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "usage: needle-eval <tools.json> [system-facts] [weights.cact]\n";
        return 2;
    }

    const std::string tools = read_file(argv[1]);
    const char* system = argc >= 3 ? argv[2] : "";
    if (tools.empty()) {
        std::cerr << "tools file is empty\n";
        return 1;
    }
    if (argc >= 4) {
        const auto weights = read_bytes(argv[3]);
        if (weights.empty()) {
            std::cerr << "weights file is empty or unreadable\n";
            return 1;
        }
        const int load_code = needle_load(weights.data(), weights.size());
        if (load_code < 0) {
            std::cerr << "needle_load failed: " << load_code << "\n";
            return 1;
        }
    }
    const int init_code = needle_init(system, tools.c_str(), nullptr);
    if (init_code < 0) {
        std::cerr << "needle_init failed: " << init_code << "\n";
        return 1;
    }

    std::vector<char> output(16 * 1024);
    std::string prompt;
    while (std::getline(std::cin, prompt)) {
        if (prompt.empty()) continue;
        needle_reset();
        const int code = needle_complete(prompt.c_str(), 256, output.data(), static_cast<int>(output.size()));
        if (code < 0) {
            std::cout << "{\"error_code\":" << code << "}\n";
        } else {
            std::cout << output.data() << "\n";
        }
        std::cout.flush();
    }
    return 0;
}
