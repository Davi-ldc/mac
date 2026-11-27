// ttyhints — tiny native PTY wrapper that captures ANSI-stripped command output
// between SIGUSR1 (preexec) and SIGUSR2 (precmd), extracts runnable command hints
// (such as `claude --resume <id>` or `git push --set-upstream ...`), and writes
// them atomically to $TTYHINTS_FILE for zsh-autosuggestions.
#define _DARWIN_C_SOURCE

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

#define CAP_MAX       (64 * 1024)
#define CAP_KEEP      (32 * 1024)
#define MAX_HINTS     24
#define MAX_HINT_LEN  220
#define MAX_IDLE_CMDS 4

static int sig_pipe[2] = {-1, -1};
static struct termios orig_tio;
static bool tio_saved = false;
static char hints_path[256] = {0};

static void signal_handler(int sig) {
    char tag = 0;
    switch (sig) {
    case SIGWINCH: tag = 'W'; break;
    case SIGUSR1:  tag = '1'; break;
    case SIGUSR2:  tag = '2'; break;
    case SIGCHLD:  tag = 'C'; break;
    case SIGHUP:   tag = 'H'; break;
    case SIGTERM:  tag = 'T'; break;
    case SIGQUIT:  tag = 'Q'; break;
    default: return;
    }
    int saved = errno;
    (void)write(sig_pipe[1], &tag, 1);
    errno = saved;
}

static void restore_tty(void) {
    if (tio_saved) {
        tcsetattr(STDIN_FILENO, TCSANOW, &orig_tio);
        tio_saved = false;
    }
}

static void cleanup_files(void) {
    if (hints_path[0]) {
        unlink(hints_path);
        hints_path[0] = '\0';
    }
}

static bool write_all(int fd, const uint8_t *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        buf += (size_t)n;
        len -= (size_t)n;
    }
    return true;
}

// --- ANSI stripper + line capture buffer ---

enum ansi_state {
    ST_NORMAL = 0,
    ST_ESC,
    ST_CSI,
    ST_OSC,
    ST_OSC_ESC,
    ST_DCS,
    ST_DCS_ESC,
    ST_CHARSET,
};

struct capture {
    char buf[CAP_MAX + 1];
    size_t len;
    enum ansi_state st;
    char csi[32];
    size_t csi_len;
    bool in_alt_screen;
    bool capturing;
    bool saw_cr;
};

static void cap_reset(struct capture *c) {
    c->len = 0;
    c->buf[0] = '\0';
    c->st = ST_NORMAL;
    c->csi_len = 0;
    c->in_alt_screen = false;
    c->saw_cr = false;
}

static void cap_append(struct capture *c, char ch) {
    if (!c->capturing || c->in_alt_screen) return;
    if (c->len >= CAP_MAX) {
        // Keep the newest CAP_KEEP bytes, starting at a line boundary if possible.
        size_t drop = c->len - CAP_KEEP;
        char *nl = memchr(c->buf + drop, '\n', CAP_KEEP);
        if (nl) drop = (size_t)(nl - c->buf) + 1;
        size_t rem = c->len - drop;
        memmove(c->buf, c->buf + drop, rem);
        c->len = rem;
    }
    c->buf[c->len++] = ch;
    c->buf[c->len] = '\0';
}

static void cap_rewind_line(struct capture *c) {
    while (c->len > 0 && c->buf[c->len - 1] != '\n') {
        c->len--;
    }
    c->buf[c->len] = '\0';
}

static void cap_feed(struct capture *c, const uint8_t *data, size_t n) {
    for (size_t i = 0; i < n; i++) {
        uint8_t b = data[i];
        switch (c->st) {
        case ST_NORMAL:
            if (b == 0x1b) {
                c->st = ST_ESC;
            } else if (b == '\r') {
                c->saw_cr = true;
            } else if (b == '\n') {
                c->saw_cr = false;
                cap_append(c, '\n');
            } else if (b == '\b') {
                if (c->capturing && !c->in_alt_screen && c->len > 0 && c->buf[c->len - 1] != '\n') {
                    c->len--;
                    c->buf[c->len] = '\0';
                }
            } else if (b == '\t') {
                if (c->saw_cr) {
                    cap_rewind_line(c);
                    c->saw_cr = false;
                }
                cap_append(c, ' ');
            } else if (b >= 0x20 && b != 0x7f) {
                if (c->saw_cr) {
                    cap_rewind_line(c);
                    c->saw_cr = false;
                }
                cap_append(c, (char)b);
            }
            break;

        case ST_ESC:
            if (b == '[') {
                c->st = ST_CSI;
                c->csi_len = 0;
            } else if (b == ']') {
                c->st = ST_OSC;
            } else if (b == 'P' || b == 'X' || b == '^' || b == '_') {
                c->st = ST_DCS;
            } else if (b == '(' || b == ')' || b == '*' || b == '+') {
                c->st = ST_CHARSET;
            } else {
                c->st = ST_NORMAL;
            }
            break;

        case ST_CSI:
            if (b >= 0x30 && b <= 0x3f) {
                if (c->csi_len + 1 < sizeof(c->csi)) {
                    c->csi[c->csi_len++] = (char)b;
                }
            } else if (b >= 0x20 && b <= 0x2f) {
                // Intermediate bytes; ignore.
            } else if (b >= 0x40 && b <= 0x7e) {
                c->csi[c->csi_len] = '\0';
                if ((strcmp(c->csi, "?1049") == 0 ||
                     strcmp(c->csi, "?47") == 0 ||
                     strcmp(c->csi, "?1047") == 0)) {
                    if (b == 'h') c->in_alt_screen = true;
                    else if (b == 'l') c->in_alt_screen = false;
                } else if (b == 'C') {
                    cap_append(c, ' ');
                }
                c->st = ST_NORMAL;
            } else {
                c->st = ST_NORMAL;
            }
            break;

        case ST_OSC:
            if (b == 0x07) c->st = ST_NORMAL;
            else if (b == 0x1b) c->st = ST_OSC_ESC;
            break;

        case ST_OSC_ESC:
            c->st = (b == '\\') ? ST_NORMAL : ST_OSC;
            break;

        case ST_DCS:
            if (b == 0x1b) c->st = ST_DCS_ESC;
            break;

        case ST_DCS_ESC:
            c->st = (b == '\\') ? ST_NORMAL : ST_DCS;
            break;

        case ST_CHARSET:
            c->st = ST_NORMAL;
            break;
        }
    }
}

// --- Command hint extraction ---

struct hint_list {
    char items[MAX_HINTS][MAX_HINT_LEN];
    size_t count;
};

static void hints_add(struct hint_list *list, const char *s) {
    if (!s || !*s || list->count >= MAX_HINTS) return;
    size_t len = strlen(s);
    if (len < 4 || len >= MAX_HINT_LEN) return;
    for (size_t i = 0; i < list->count; i++) {
        if (strcmp(list->items[i], s) == 0) return;
    }
    memcpy(list->items[list->count], s, len + 1);
    list->count++;
}

static bool is_known_cmd(const char *tok, size_t len) {
    static const char *const cmds[] = {
        "claude", "cskip", "c", "git", "npm", "npx", "yarn", "pnpm", "bun", "bunx",
        "node", "deno", "python", "python3", "pip", "pip3", "uv", "pytest",
        "cargo", "rustc", "go", "make", "cmake", "brew", "docker", "kubectl",
        "helm", "gh", "gcloud", "aws", "supabase", "vercel", "curl", "ssh",
        "scp", "rsync", "cd", "ls", "ll", "eza", "bat", "cat", "open", "code",
        "zed", "vim", "nvim", "kill", "pkill", "lsof", "chmod", "chown",
        "mkdir", "rm", "mv", "cp", "ln", "tar", "unzip", "export", "source",
        "exec", "sudo", "deskkit", "acc", "antigravity-claude-proxy", "swift",
        "xcodebuild", "clang", "tmux", "fzf", "zoxide", "rg", "jq", "tail",
        "head", "grep", "find", "which", "man", "env", "unset",
    };
    for (size_t i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++) {
        if (strlen(cmds[i]) == len && memcmp(cmds[i], tok, len) == 0) return true;
    }
    return false;
}

static bool is_prose_stopword(const char *tok, size_t len) {
    static const char *const words[] = {
        "the", "a", "an", "to", "for", "of", "in", "on", "is", "are", "was",
        "were", "be", "it", "this", "that", "these", "those", "your", "my",
        "you", "we", "they", "and", "or", "but", "with", "from", "not", "no",
        "sure", "sense", "out", "up", "into", "over", "about", "as", "by",
        "at", "if", "when", "can", "will", "should", "must", "have", "has",
        "o", "os", "um", "uma", "de", "do", "da", "dos", "das", "para",
        "com", "em", "na", "que", "por", "se", "ou", "nao",
    };
    char lower[24];
    if (len == 0 || len >= sizeof(lower)) return false;
    for (size_t i = 0; i < len; i++) lower[i] = (char)tolower((unsigned char)tok[i]);
    lower[len] = '\0';
    for (size_t i = 0; i < sizeof(words) / sizeof(words[0]); i++) {
        if (strcmp(words[i], lower) == 0) return true;
    }
    return false;
}

static bool is_ambiguous_word_cmd(const char *tok, size_t len) {
    static const char *const ambig[] = {
        "c", "go", "make", "open", "cat", "find", "head", "tail", "kill",
        "source", "export", "env", "man", "which", "code", "cd", "ln", "rm",
    };
    for (size_t i = 0; i < sizeof(ambig) / sizeof(ambig[0]); i++) {
        if (strlen(ambig[i]) == len && memcmp(ambig[i], tok, len) == 0) return true;
    }
    return false;
}

static void trim_inplace(char *s) {
    char *p = s;
    while (*p && isspace((unsigned char)*p)) p++;
    if (p != s) memmove(s, p, strlen(p) + 1);
    size_t len = strlen(s);
    while (len > 0 && isspace((unsigned char)s[len - 1])) {
        s[--len] = '\0';
    }
}

static void strip_prompt_prefix(char *s) {
    trim_inplace(s);
    // Strip leading "$ ", "% ", "> ", "- "
    if ((s[0] == '$' || s[0] == '%' || s[0] == '>' || s[0] == '-') && s[1] == ' ') {
        memmove(s, s + 2, strlen(s + 2) + 1);
        trim_inplace(s);
    }
    // Strip matching outer quotes/backticks
    size_t len = strlen(s);
    if (len >= 2 && ((s[0] == '`' && s[len - 1] == '`') ||
                     (s[0] == '"' && s[len - 1] == '"') ||
                     (s[0] == '\'' && s[len - 1] == '\''))) {
        s[len - 1] = '\0';
        memmove(s, s + 1, len - 1);
        trim_inplace(s);
    }
}

static bool is_plausible_command(const char *s) {
    size_t len = strlen(s);
    if (len < 4 || len >= MAX_HINT_LEN) return false;

    // Reject obvious sentence endings (keep `..` and ` .`).
    char last = s[len - 1];
    if (last == '?' || last == '!' || last == ':' || last == ',' || last == ';') return false;
    if (last == '.' && len >= 2 && s[len - 2] != '.' && s[len - 2] != ' ') return false;

    // Parse tokens.
    const char *p = s;
    const char *tok1 = p;
    while (*p && !isspace((unsigned char)*p)) p++;
    size_t tok1_len = (size_t)(p - tok1);
    if (!is_known_cmd(tok1, tok1_len)) return false;

    while (*p && isspace((unsigned char)*p)) p++;
    if (!*p) return false; // Must have at least one argument.

    const char *tok2 = p;
    while (*p && !isspace((unsigned char)*p)) p++;
    size_t tok2_len = (size_t)(p - tok2);

    if (is_ambiguous_word_cmd(tok1, tok1_len) && is_prose_stopword(tok2, tok2_len)) {
        return false;
    }

    // Count total tokens; real suggested commands rarely exceed 12 tokens.
    int tokens = 2;
    while (*p) {
        while (*p && isspace((unsigned char)*p)) p++;
        if (!*p) break;
        tokens++;
        if (tokens > 12) return false;
        while (*p && !isspace((unsigned char)*p)) p++;
    }
    return true;
}

static bool contains_cue_word(const char *line) {
    static const char *const cues[] = {
        "run", "try", "use", "execute", "resume", "continue", "command", "hint",
    };
    char lower[512];
    size_t n = strlen(line);
    if (n >= sizeof(lower)) n = sizeof(lower) - 1;
    for (size_t i = 0; i < n; i++) lower[i] = (char)tolower((unsigned char)line[i]);
    lower[n] = '\0';
    for (size_t i = 0; i < sizeof(cues) / sizeof(cues[0]); i++) {
        if (strstr(lower, cues[i])) return true;
    }
    return false;
}

static void extract_resume_from_line(struct hint_list *out, const char *line) {
    const char *p = line;
    while ((p = strstr(p, "--resume")) != NULL) {
        const char *q = p + 8;
        if (*q == '=' || isspace((unsigned char)*q)) {
            if (*q == '=') q++;
            while (*q && isspace((unsigned char)*q)) q++;
            // Skip optional opening quote around ID
            if (*q == '"' || *q == '\'' || *q == '`') q++;
            const char *start = q;
            while (*q && (isalnum((unsigned char)*q) || *q == '-' || *q == '_')) q++;
            size_t idlen = (size_t)(q - start);
            if (idlen >= 6 && idlen < 128) {
                char id[128];
                memcpy(id, start, idlen);
                id[idlen] = '\0';
                char buf[MAX_HINT_LEN];
                snprintf(buf, sizeof(buf), "claude --resume %s", id);
                hints_add(out, buf);
                snprintf(buf, sizeof(buf), "cskip --resume %s", id);
                hints_add(out, buf);
                snprintf(buf, sizeof(buf), "c --resume %s", id);
                hints_add(out, buf);
                snprintf(buf, sizeof(buf), "--resume %s", id);
                hints_add(out, buf);
            }
        }
        p += 8;
    }
}

static void extract_quoted_from_line(struct hint_list *out, const char *line) {
    if (!contains_cue_word(line)) return;
    static const char quotes[3] = {'`', '"', '\''};
    for (int qi = 0; qi < 3; qi++) {
        char q = quotes[qi];
        const char *p = line;
        while ((p = strchr(p, q)) != NULL) {
            const char *end = strchr(p + 1, q);
            if (!end) break;
            size_t len = (size_t)(end - (p + 1));
            if (len >= 4 && len < MAX_HINT_LEN) {
                char cand[MAX_HINT_LEN];
                memcpy(cand, p + 1, len);
                cand[len] = '\0';
                strip_prompt_prefix(cand);
                if (is_plausible_command(cand)) {
                    hints_add(out, cand);
                }
            }
            p = end + 1;
        }
    }
}

static void extract_hints_from_capture(const struct capture *c, struct hint_list *out) {
    out->count = 0;
    if (c->len == 0) return;

    // Walk lines bottom-to-top so the most recent output gets highest priority.
    size_t end = c->len;
    while (end > 0 && out->count < MAX_HINTS) {
        size_t start = end;
        while (start > 0 && c->buf[start - 1] != '\n') start--;

        size_t linelen = end - start;
        if (linelen > 0 && linelen < 512) {
            char line[512];
            memcpy(line, c->buf + start, linelen);
            line[linelen] = '\0';
            trim_inplace(line);

            if (line[0] != '\0') {
                extract_resume_from_line(out, line);
                extract_quoted_from_line(out, line);

                char direct[512];
                memcpy(direct, line, strlen(line) + 1);
                strip_prompt_prefix(direct);
                if (is_plausible_command(direct)) {
                    hints_add(out, direct);
                }
            }
        }
        end = (start > 0) ? start - 1 : 0;
    }
}

static void write_hints_atomic(const struct hint_list *list) {
    if (!hints_path[0]) return;
    char tmp[280];
    snprintf(tmp, sizeof(tmp), "%s.tmp", hints_path);

    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;

    for (size_t i = 0; i < list->count; i++) {
        size_t len = strlen(list->items[i]);
        if (!write_all(fd, (const uint8_t *)list->items[i], len) ||
            !write_all(fd, (const uint8_t *)"\n", 1)) {
            close(fd);
            unlink(tmp);
            return;
        }
    }
    close(fd);
    rename(tmp, hints_path);
}

static void merge_hints(struct hint_list *persisted, const struct hint_list *fresh, int *idle_cmds) {
    if (fresh->count == 0) {
        (*idle_cmds)++;
        if (*idle_cmds > MAX_IDLE_CMDS) {
            persisted->count = 0;
            write_hints_atomic(persisted);
        }
        return;
    }

    *idle_cmds = 0;
    struct hint_list merged = {0};
    for (size_t i = 0; i < fresh->count; i++) hints_add(&merged, fresh->items[i]);
    for (size_t i = 0; i < persisted->count; i++) hints_add(&merged, persisted->items[i]);
    *persisted = merged;
    write_hints_atomic(persisted);
}

// --- Child execution helpers ---

static void exec_direct(int argc, char **argv, bool login_shell, int start_idx) {
    if (start_idx >= argc) {
        const char *shell = getenv("SHELL");
        if (!shell || !*shell) shell = "/bin/zsh";
        const char *base = strrchr(shell, '/');
        base = base ? base + 1 : shell;
        char arg0[128];
        snprintf(arg0, sizeof(arg0), "-%s", base);
        char *args[] = {arg0, NULL};
        execvp(shell, args);
        _exit(127);
    }

    if (login_shell) {
        const char *path = argv[start_idx];
        const char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        char arg0[128];
        snprintf(arg0, sizeof(arg0), "-%s", base);
        int n = argc - start_idx;
        char **args = calloc((size_t)n + 1, sizeof(char *));
        if (!args) _exit(127);
        args[0] = arg0;
        for (int i = 1; i < n; i++) args[i] = argv[start_idx + i];
        execvp(path, args);
        _exit(127);
    }

    execvp(argv[start_idx], &argv[start_idx]);
    _exit(127);
}

int main(int argc, char **argv) {
    bool login_shell = false;
    int start_idx = 1;
    if (argc > 1 && strcmp(argv[1], "--login") == 0) {
        login_shell = true;
        start_idx = 2;
    }

    // Do not wrap non-interactive invocations or nested shells.
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO) || getenv("TTYHINTS_PID") != NULL) {
        exec_direct(argc, argv, login_shell, start_idx);
    }

    if (pipe(sig_pipe) < 0) {
        exec_direct(argc, argv, login_shell, start_idx);
    }
    for (int i = 0; i < 2; i++) {
        int fl = fcntl(sig_pipe[i], F_GETFL, 0);
        if (fl >= 0) fcntl(sig_pipe[i], F_SETFL, fl | O_NONBLOCK);
        fcntl(sig_pipe[i], F_SETFD, FD_CLOEXEC);
    }

    struct winsize ws = {0};
    ioctl(STDIN_FILENO, TIOCGWINSZ, &ws);
    if (tcgetattr(STDIN_FILENO, &orig_tio) == 0) {
        tio_saved = true;
    }

    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir || !*tmpdir) tmpdir = "/tmp";
    size_t tlen = strlen(tmpdir);
    while (tlen > 1 && tmpdir[tlen - 1] == '/') tlen--;
    snprintf(hints_path, sizeof(hints_path), "%.*s/ttyhints-%d.txt",
             (int)tlen, tmpdir, (int)getpid());

    char pid_str[32];
    snprintf(pid_str, sizeof(pid_str), "%d", (int)getpid());

    struct sigaction sa = {0};
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGWINCH, &sa, NULL);
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
    sigaction(SIGCHLD, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGQUIT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTSTP, SIG_IGN);
    signal(SIGTTIN, SIG_IGN);
    signal(SIGTTOU, SIG_IGN);

    int master = -1;
    pid_t child = forkpty(&master, NULL, tio_saved ? &orig_tio : NULL, &ws);
    if (child < 0) {
        restore_tty();
        exec_direct(argc, argv, login_shell, start_idx);
    }

    if (child == 0) {
        // Restore default signals in child.
        signal(SIGWINCH, SIG_DFL);
        signal(SIGUSR1, SIG_DFL);
        signal(SIGUSR2, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGTSTP, SIG_DFL);
        signal(SIGTTIN, SIG_DFL);
        signal(SIGTTOU, SIG_DFL);

        setenv("TTYHINTS_FILE", hints_path, 1);
        setenv("TTYHINTS_PID", pid_str, 1);
        exec_direct(argc, argv, login_shell, start_idx);
    }

    // Put outer terminal into raw mode so all keystrokes pass transparently.
    if (tio_saved) {
        struct termios raw = orig_tio;
        cfmakeraw(&raw);
        tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    }

    static struct capture cap;
    cap_reset(&cap);
    static struct hint_list persisted;
    int idle_cmds = 0;

    bool stdin_open = true;
    bool master_open = true;
    bool child_exited = false;
    int child_status = 0;

    uint8_t io_buf[8192];

    while (master_open) {
        struct pollfd fds[3];
        nfds_t nfds = 0;

        int idx_sig = (int)nfds;
        fds[nfds].fd = sig_pipe[0];
        fds[nfds].events = POLLIN;
        nfds++;

        int idx_master = (int)nfds;
        fds[nfds].fd = master;
        fds[nfds].events = POLLIN;
        nfds++;

        int idx_stdin = -1;
        if (stdin_open) {
            idx_stdin = (int)nfds;
            fds[nfds].fd = STDIN_FILENO;
            fds[nfds].events = POLLIN;
            nfds++;
        }

        int rc = poll(fds, nfds, -1);
        if (rc < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (fds[idx_sig].revents & POLLIN) {
            char tags[64];
            ssize_t n;
            while ((n = read(sig_pipe[0], tags, sizeof(tags))) > 0) {
                for (ssize_t i = 0; i < n; i++) {
                    switch (tags[i]) {
                    case 'W':
                        if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0) {
                            ioctl(master, TIOCSWINSZ, &ws);
                        }
                        break;
                    case '1':
                        cap_reset(&cap);
                        cap.capturing = true;
                        break;
                    case '2': {
                        // Drain any output still buffered in master before extracting.
                        struct pollfd mp = {.fd = master, .events = POLLIN};
                        while (poll(&mp, 1, 0) > 0 && (mp.revents & POLLIN)) {
                            ssize_t m = read(master, io_buf, sizeof(io_buf));
                            if (m <= 0) break;
                            write_all(STDOUT_FILENO, io_buf, (size_t)m);
                            cap_feed(&cap, io_buf, (size_t)m);
                        }
                        cap.capturing = false;
                        struct hint_list fresh;
                        extract_hints_from_capture(&cap, &fresh);
                        merge_hints(&persisted, &fresh, &idle_cmds);
                        break;
                    }
                    case 'C':
                        if (waitpid(child, &child_status, WNOHANG) == child) {
                            child_exited = true;
                        }
                        break;
                    case 'H': kill(-child, SIGHUP); break;
                    case 'T': kill(-child, SIGTERM); break;
                    case 'Q': kill(-child, SIGQUIT); break;
                    }
                }
            }
        }

        if (fds[idx_master].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(master, io_buf, sizeof(io_buf));
            if (n > 0) {
                write_all(STDOUT_FILENO, io_buf, (size_t)n);
                cap_feed(&cap, io_buf, (size_t)n);
            } else if (n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN)) {
                master_open = false;
            }
        }

        if (idx_stdin >= 0 && (fds[idx_stdin].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t n = read(STDIN_FILENO, io_buf, sizeof(io_buf));
            if (n > 0) {
                if (!write_all(master, io_buf, (size_t)n)) master_open = false;
            } else if (n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN)) {
                stdin_open = false;
            }
        }

        if (child_exited && master_open) {
            struct pollfd mp = {.fd = master, .events = POLLIN};
            if (poll(&mp, 1, 20) <= 0) {
                master_open = false;
            }
        }
    }

    close(master);
    if (!child_exited) {
        while (waitpid(child, &child_status, 0) < 0 && errno == EINTR) {}
    }

    restore_tty();
    cleanup_files();

    if (WIFEXITED(child_status)) return WEXITSTATUS(child_status);
    if (WIFSIGNALED(child_status)) return 128 + WTERMSIG(child_status);
    return 0;
}
