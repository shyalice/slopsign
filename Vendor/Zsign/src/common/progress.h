#pragma once
#include <functional>
#include <chrono>
#include <algorithm>
#include <mutex>

// Serialized by SigningEngine. Units count actual resource hashes and code
// objects, including resources sealed by more than one enclosing bundle.
namespace ZWork {
inline std::function<void(double)> handler;
inline uint64_t total=1, completed=0;
inline std::mutex mutex;
inline std::chrono::steady_clock::time_point last;
inline void report(bool force=false) {
 auto now=std::chrono::steady_clock::now();
 if(!force && now-last<std::chrono::milliseconds(60))return;
 last=now;if(handler)handler(std::min(0.999,double(completed)/double(total)));
}
inline void begin(uint64_t units) { std::lock_guard<std::mutex> lock(mutex); total=std::max(uint64_t(1),units);completed=0;last={};report(true); }
inline void advance() {std::lock_guard<std::mutex> lock(mutex);completed++;report();}
inline void finish() {std::lock_guard<std::mutex> lock(mutex);if(handler)handler(1);}
}
