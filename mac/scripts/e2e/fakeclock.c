// 시나리오 시험용 시계: DYLD_INSERT_LIBRARIES 로 시험 실행에만 끼운다(앱 코드·일반 실행과 무관).
// DROPCAP_CLOCK_FILE 에 적힌 초(실수)만큼 '벽시계'(CLOCK_REALTIME·gettimeofday)를 앞당긴다.
// Date()·CFAbsoluteTimeGetCurrent 는 이 둘을 쓰므로 앱의 '지금'이 바뀐다. 타이머·Task.sleep 은 단조 시계라 그대로.
// 파일은 50ms 마다 다시 읽어, 실행 중에 시나리오가 시계를 옮길 수 있다.
#include <time.h>
#include <sys/time.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

static double cached = 0;
static uint64_t lastRead = 0;

static long offset(void) {
    uint64_t t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); // 이 라이브러리 안의 호출은 끼워 넣기 대상이 아님
    if (lastRead == 0 || t - lastRead > 50000000ULL) {
        lastRead = t;
        const char *f = getenv("DROPCAP_CLOCK_FILE");
        double v = 0;
        if (f) {
            FILE *fp = fopen(f, "r");
            if (fp) { if (fscanf(fp, "%lf", &v) != 1) v = 0; fclose(fp); }
        }
        cached = v;
    }
    return (long)cached;
}

static int e2e_clock_gettime(clockid_t c, struct timespec *ts) {
    int r = clock_gettime(c, ts);
    if (r == 0 && ts && c == CLOCK_REALTIME) ts->tv_sec += offset();
    return r;
}

static int e2e_gettimeofday(struct timeval *tv, void *tz) {
    int r = gettimeofday(tv, tz);
    if (r == 0 && tv) tv->tv_sec += offset();
    return r;
}

static uint64_t e2e_clock_gettime_nsec_np(clockid_t c) {
    uint64_t v = clock_gettime_nsec_np(c);
    if (c == CLOCK_REALTIME) v += (uint64_t)((int64_t)offset() * 1000000000LL);
    return v;
}

static time_t e2e_time(time_t *out) {
    time_t t = time(NULL) + offset();
    if (out) *out = t;
    return t;
}

__attribute__((used)) static struct { const void *replacement; const void *original; } interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)e2e_clock_gettime, (const void *)clock_gettime },
    { (const void *)e2e_gettimeofday, (const void *)gettimeofday },
    { (const void *)e2e_clock_gettime_nsec_np, (const void *)clock_gettime_nsec_np },
    { (const void *)e2e_time, (const void *)time },
};
