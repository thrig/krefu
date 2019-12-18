/* krefu - a small flashcard program. the C (maybe) sets up curses but
 * then calls into main.tcl where most all the logic is */

#include <err.h>
#include <locale.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>
#include <unistd.h>

#include <curses.h>
#include <tcl.h>

Tcl_Interp *Interp;

static int init_curses(ClientData clientData, Tcl_Interp * interp, int objc,
                       Tcl_Obj * CONST objv[]);
/* some flavor of POSIX apparently has wordexp.h; that might be a better
 * option for OS that have that */
char *texpand(const char *s);

int main(int argc, char *argv[])
{
    /* advised for curses but then would require [system encoding utf-8]
     * or whatever over on the TCL side of things, or to re-encoding
     * using iso8859-1 ... */
    //setlocale(LC_ALL, "");

    if ((Interp = Tcl_CreateInterp()) == NULL)
        errx(EX_OSERR, "Tcl_CreateInterp failed");
    if (Tcl_Init(Interp) == TCL_ERROR)
        errx(EX_OSERR, "Tcl_Init failed");

    if (Tcl_CreateObjCommand
        (Interp, "init_curses", init_curses, (ClientData) NULL,
         (Tcl_CmdDeleteProc *) NULL) == NULL)
        errx(1, "Tcl_CreateObjCommand failed");

    char *args = Tcl_Merge(argc - 1, (const char *const *) argv + 1);
    Tcl_SetVar(Interp, "argv", args, TCL_GLOBAL_ONLY);
    //Tcl_Free(args);

    char *kdir = texpand(getenv("KREFU_DIR"));
    Tcl_SetVar(Interp, "kdir", kdir, TCL_GLOBAL_ONLY);

    char *main;
    asprintf(&main, "%s/main.tcl", kdir);

    int ret;
    if ((ret = Tcl_EvalFile(Interp, main)) != TCL_OK) {
        if (ret == TCL_ERROR) {
            Tcl_Obj *options = Tcl_GetReturnOptions(Interp, ret);
            Tcl_Obj *key = Tcl_NewStringObj("-errorinfo", -1);
            Tcl_Obj *stacktrace;
            Tcl_IncrRefCount(key);
            Tcl_DictObjGet(NULL, options, key, &stacktrace);
            Tcl_DecrRefCount(key);
            fputs(Tcl_GetStringFromObj(stacktrace, NULL), stderr);
            fputs("\n", stderr);
        }
        errx(1, "%s failed: %s", main, Tcl_GetStringResult(Interp));
    }
    //free(kdir);
    exit(EXIT_SUCCESS);
}

void cleanup(void)
{
    noraw();
    echo();
    curs_set(TRUE);
    endwin();
}

static int init_curses(ClientData clientData, Tcl_Interp * interp, int objc,
                       Tcl_Obj * CONST objv[])
{
    initscr();
    atexit(cleanup);
    curs_set(FALSE);
    raw();
    noecho();
    nonl();
    clearok(stdscr, TRUE);
    refresh();
    return TCL_OK;
}

char *texpand(const char *s)
{
    if (s == NULL || s[0] == '\0') {
        return texpand("~/share/krefu");
    } else if (s[0] == '~') {
        char *out;
        struct passwd *p;
        if (s[1] == '/' || s[1] == '\0') {
            char *home;
            if ((home = getenv("HOME")) == NULL) {
                if ((p = getpwuid(getuid())) == NULL)
                    err(1, "cannot find HOME directory");
                home = p->pw_dir;
            }
            asprintf(&out, "%s%s", home, &s[1]);
        } else {
            char *user = strdup(&s[1]);
            char *end = strchr(user, '/');
            if (end != NULL)
                *end = '\0';
            if ((p = getpwnam(user)) == NULL)
                err(1, "cannot lookup user %s", user);
            free(user);
            asprintf(&out, "%s%s", p->pw_dir,
                     end == NULL ? "" : s + (end - user + 1));
        }
        return out;
    } else {
        return strdup(s);
    }
    /* NOTREACHED (I hope) */
}
