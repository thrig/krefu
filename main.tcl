# krefu - a small flashcard program

package require Tcl 8.6
package require sqlite3 3.24.0

namespace path {::tcl::mathop ::tcl::mathfunc}

set dbfile [file join $kdir krefu.db]

# assumes `sox` and `feh` are installed (or point to something suitable)
set mediacmd [dict create audio play image feh]

# see also logic in spaced_rep
set score_min 0
set score_max 9

proc bail_out {{status 0} {msg {}}} {
    if {[string length $msg]} {puts stderr $msg}
    exit $status
}

proc bold {text} {
    append ret \033\[1m $text \033\[0m
    return $ret
}

# borrowed from the CommonLISP alexandria library
proc clamp {n min max} {
    if {$n < $min} {return $min} \
    elseif {$n > $max} {return $max} \
    else {return $n}
}

# type 1 (front/back) cards also need a type -1 (back/front) reverse,
# but only after the type 1 card is first trained
proc create_reverse {} {
    global card deck
    set epoch [+ [clock seconds] $deck(nperiod)]
    catch {
        db eval {
            INSERT INTO cards (cardid,type,mtime)
            VALUES($card(cardid),-1,$epoch)
        }
    }
}

proc delete_media {args} {
    foreach media $args {
        foreach spec [split $media \ ] {
            if {[regexp {^([^:]+):(.+)} $spec -> type path]} {
                file delete [file normalize $path]
            }
        }
    }
}

proc handle_media {media} {
    global card mediacmd
    # NOTE this means that spaces in filenames are not permitted (the
    # test code also rejects spaces in KERFU_DIR)
    foreach spec [split $media \ ] {
        if {[regexp {^([^:]+):(.+)} $spec -> type path]} {
            if {[dict exists $mediacmd $type]} {
                exec -ignorestderr -- {*}[dict get $mediacmd $type] \
                  [file normalize $path] < /dev/null >& /dev/null &
            } else {
                puts stderr "unknown media type cardid=$card(cardid): $type"
            }
        } else {
            puts stderr "invalid media cardid=$card(cardid): $media"
        }
    }
}

# is the card known or not? plus the various consequences thereof
proc known {isnew} {
    global card db deck
    while 1 {
        switch [read stdin 1] {
            Q {bail_out}
            I {
                db eval {
                    UPDATE cards SET active = FALSE
                    WHERE cardid = $card(cardid)
                }
                return
            }
            y {score_incr card(score);break}
            n {
                score_incr card(score) -1
                # TWEAK if miss back/front perhaps show the usually
                # easier front/back sooner to help out with the miss
                # (this may end up annoying me if the same cardset is
                # shown too much?)
                if {$card(type) == -1 && rand() < 0.5} {
                    set frontscore [db onecolumn {
                        SELECT score FROM cards
                        WHERE cardid = $card(cardid) AND type = 1
                    }]
                    score_incr frontscore -1
                    db eval {
                        UPDATE cards SET score=$frontscore
                        WHERE cardid = $card(cardid) AND type = 1
                    }
                }
                break
            }
        }
    }
    set active 1
    set epoch [spaced_rep $card(score)]
    incr card(seen)
    # TWEAK do not show card too much to avoid fatigue
    #if {$card(seen) > 20} {set active 0}
    # leech? disable the card as not getting anywhere with it
    # TODO will probably also need disable both of pairs, also need
    # better log of things that have too many misses... hmm
    #if {$card(seen) > 10 && $card(score) < 1} {set active 0}
    db eval {
        UPDATE cards SET mtime = $epoch,
          score = $card(score), seen = $card(seen), active = $active
        WHERE cardid = $card(cardid) AND type = $card(type)
    }
    if {$isnew} {incr deck(ndone)} else {incr deck(rdone)}
    db eval {
        UPDATE decks SET ntime = $deck(ntime), rtime = $deck(rtime),
          ndone = $deck(ndone), rdone = $deck(rdone)
        WHERE deckid = $deck(deckid)
    }
}

# krefu commands. more will doubtless need to be added though some
# things can also be done by poking around in the database directly
proc main {} {
    global argv command db dbfile kdir
    set command [lindex $argv 0]
    if {$command eq ""} {puts stderr "Usage: krefu command";exit 64}
    switch $command {
        train {
            set dname [lindex $argv 1]
            if {$dname eq ""} {
                puts stderr "Usage: krefu train deck-name"
                exit 64
            }
            sqlite3 db $dbfile -create 0 -nomutex 1
            init_curses
            fconfigure stdout -buffering none
            traindeck $dname
        }
        trainrand {
            sqlite3 db $dbfile -create 0 -nomutex 1
            set decks [db onecolumn {SELECT deck FROM decks}]
            set len [llength $decks]
            if {$len == 0} {
                puts stderr "no decks to train on"
                exit 1
            }
            set dname [lindex $decks [expr {int($len*rand())}]]
            puts $dname
            after 500
            init_curses
            fconfigure stdout -buffering none
            traindeck $dname
        }
        add {
            if {[llength $argv] < 4} {
                puts stderr \
                  {Usage: krefu add deck type front [back [fmedia [bmedia]]]}
                exit 64
            }
            sqlite3 db $dbfile -create 0 -nomutex 1
            set dname [lindex $argv 1]
            set type [lindex $argv 2]
            set front [lindex $argv 3]
            set back [lindex $argv 4]
            set fmedia [lindex $argv 5]
            set bmedia [lindex $argv 6]
            db transaction {
                set deckid \
                  [db onecolumn {SELECT deckid FROM decks WHERE deck = $dname}]
                if {$deckid eq ""} {
                    db eval {INSERT INTO decks(deck) VALUES($dname)}
                    set deckid [db last_insert_rowid]
                }
                db eval {
                    INSERT INTO cardinfo(front,back,fmedia,bmedia)
                    VALUES($front,$back,$fmedia,$bmedia)
                }
                set cardid [db last_insert_rowid]
                db eval {INSERT INTO cards(cardid,type) VALUES($cardid,$type)}
                db eval {INSERT INTO carddecks VALUES($cardid,$deckid)}
            }
        }
        decks {
            sqlite3 db $dbfile -create 0 -nomutex 1
            db eval {SELECT deckid,deck FROM decks} deck {
                # total new count to see how stuffed a deck is with new cards
                set new [db onecolumn {
                    SELECT COUNT(*) FROM cards
                    INNER JOIN carddecks USING (cardid)
                    WHERE deckid = $deck(deckid) AND mtime = 0
                }]
                puts "$deck(deck) $new"
            }
        }
        list {
            set dname [lindex $argv 1]
            if {$dname eq ""} {
                puts stderr "Usage: krefu list deck-name"
                exit 64
            }
            sqlite3 db $dbfile -create 0 -nomutex 1
            set ret 1
            db eval {
                SELECT DISTINCT cardid,active,front,back
                FROM (cardinfo INNER JOIN carddecks USING (cardid)
                INNER JOIN cards USING (cardid))
                WHERE deckid IN (SELECT deckid FROM decks WHERE deck = $dname)
            } card {
                puts "$card(cardid) $card(active) {$card(front)} {$card(back)}"
                set ret 0
            }
            if {$ret} {puts stderr "no cards for $dname"}
            exit $ret
        }
        delete {
            set dname [lindex $argv 1]
            if {$dname eq "" || [llength $argv] < 3} {
                puts stderr "Usage: krefu delete deck-name cardid \[cardid ..]"
                exit 64
            }
            sqlite3 db $dbfile -create 0 -nomutex 1
            db eval {PRAGMA foreign_keys = ON}
            db transaction {
                foreach cardid [lrange $argv 2 end] {
                    db eval {
                        SELECT fmedia,bmedia FROM cardinfo WHERE cardid=$cardid
                    } media {
                        delete_media $media(fmedia) $media(bmedia)
                    }
                    db eval {DELETE FROM cardinfo WHERE cardid=$cardid}
                }
            }
        }
        init {
            # complicates the pledge/unveil, make the directory elsewhere
            #file mkdir $kdir
            if {[file exists $dbfile]} {exit}
            sqlite3 db $dbfile -create 1 -nomutex 1
            db transaction {
                db eval {
                    CREATE TABLE cardinfo (
                      cardid INTEGER PRIMARY KEY NOT NULL,
                      front TEXT NOT NULL,
                      back TEXT,
                      fmedia TEXT,
                      bmedia TEXT
                    );
                }
                db eval {
                    CREATE TABLE cards (
                      cardid INTEGER NOT NULL,
                      type INTEGER NOT NULL,
                      active BOOLEAN NOT NULL DEFAULT TRUE,
                      mtime INTEGER NOT NULL DEFAULT 0,
                      score INTEGER NOT NULL DEFAULT 0,
                      seen INTEGER NOT NULL DEFAULT 0,
                      FOREIGN KEY(cardid) REFERENCES cardinfo(cardid)
                        ON UPDATE CASCADE ON DELETE CASCADE
                    );
                }
                db eval {
                    CREATE UNIQUE INDEX idx_cards_cardtype
                    ON cards(cardid,type);
                }
                db eval {
                    CREATE INDEX idx_cards_mtimeactive ON cards(mtime,active);
                }
                # TWEAK 'new' is how many new cards will be shown per
                # nperiod (seconds), and 'review' how many already seen
                # cards will be reviewed per rperiod. these may need to
                # vary by deck or over time, or to suit your workflow (I
                # add new Spanish cards in the evening, and lojban cards
                # in the morning, for example)
                db eval {
                    CREATE TABLE decks (
                      deckid INTEGER PRIMARY KEY NOT NULL,
                      deck TEXT UNIQUE NOT NULL,
                      new INTEGER NOT NULL DEFAULT 10,
                      review INTEGER NOT NULL DEFAULT 100,
                      ndone INTEGER NOT NULL DEFAULT 0,
                      nperiod INTEGER NOT NULL DEFAULT 50400,
                      ntime INTEGER NOT NULL DEFAULT 0,
                      rdone INTEGER NOT NULL DEFAULT 0,
                      rperiod INTEGER NOT NULL DEFAULT 50400,
                      rtime INTEGER NOT NULL DEFAULT 0
                    );
                }
                db eval {
                    CREATE TABLE carddecks (
                      cardid INTEGER NOT NULL,
                      deckid INTEGER NOT NULL,
                      FOREIGN KEY(cardid) REFERENCES cardinfo(cardid)
                        ON UPDATE CASCADE ON DELETE CASCADE,
                      FOREIGN KEY(deckid) REFERENCES decks(deckid)
                        ON UPDATE CASCADE ON DELETE CASCADE
                    );
                }
            }
        }
        default {
            puts stderr "krefu: unknown command: $command"
            exit 64
        }
    }
}

proc score_incr {var {n 1}} {
    global score_min score_max
    upvar 1 $var score
    set score [clamp [+ $score $n] $score_min $score_max]
}

proc show_answer {text media} {
    if {[string length $media]} {handle_media $media}
    if {[string length $text]} {puts -nonewline "[bold $text] "}
    puts {[y/n]}
}

proc show_question {text media} {
    puts -nonewline \033\[1\;1H\033\[2J
    if {[string length $media]} {handle_media $media}
    puts [bold $text]
}

# N is the number of cards but traincard gets an id,type,id,type,...
proc rand_cardtype {n} {expr {int($n * rand())*2}}

# pick a new or review card; the odds change as cards are trained on
proc rand_newreview {new review} {
    expr {int(($new + $review)*rand()) < $new}
}

# TWEAK intervals based on "Pimsleur's graduated-interval recall" on the
# Wikipedia "Spaced repetition" page (as of late November 2019)
proc spaced_rep {score} {
    global score_min score_max
    switch [clamp $score $score_min $score_max] {
        0 {set offset 5}
        1 {set offset 23}
        2 {set offset 113}
        3 {set offset 601}
        4 {set offset 18013}
        5 {set offset 82811}
        6 {set offset 428411}
        7 {set offset 2159959}
        8 {set offset 10299997}
        9 {set offset 63069991}
    }
    + [clock seconds] $offset
}

# train a card from a list of cardid type pairs; it might be a new or
# review card. everything is done in a transaction so quitting should
# have minimal impact on any particular session
proc traincard {limitv cardsv isnew} {
    global card db deck
    upvar 1 $limitv limit $cardsv cards
    set nth [rand_cardtype $limit]
    set cid [lindex $cards $nth]
    set type [lindex $cards [+ $nth 1]]
    db transaction {
        db eval {
            SELECT * FROM cards INNER JOIN cardinfo USING (cardid)
            WHERE cardid = $cid AND type = $type
        } card {
            if {$card(active)} {
                # 1 = 2-sided card f/b; 0 = 1-sided; -1 = 2-sided b/f
                if {$type == -1} {
                    show_question $card(back) $card(bmedia)
                } else {
                    show_question $card(front) $card(fmedia)
                    if {$card(mtime) == 0 && $card(type) == 1} {create_reverse}
                }
                if {[wait_before_answer]} {
                    if {$type == -1} {show_answer $card(front) $card(fmedia)} \
                    else {show_answer $card(back) $card(bmedia)}
                    known $isnew
                }
            }
        }
    }
    set cards [lreplace $cards $nth [+ $nth 1]]
    incr limit -1
}

# trains a deck until new and review cards run out for the given
# training period (or the user quits, or the system fails, or ...
proc traindeck {dname} {
    global db deck
    set has_deck 0
    db eval {SELECT * FROM decks WHERE deck = $dname} deck {
        set now [clock seconds]
        if {[+ $deck(ntime) $deck(nperiod)] < $now} {
            set deck(ndone) 0
            set deck(ntime) $now
        }
        if {[+ $deck(rtime) $deck(rperiod)] < $now} {
            set deck(rdone) 0
            set deck(rtime) $now
        }
        set newlim [clamp [- $deck(new) $deck(ndone)] 0 $deck(new)]
        set revlim [clamp [- $deck(review) $deck(rdone)] 0 $deck(review)]
        if {$newlim == 0 && $revlim == 0} {
            bail_out 0 "\033\[1\;1H\033\[2J$dname: no cards to train!!"
        }
        set newcards [db eval {
            SELECT cardid,type FROM cards INNER JOIN carddecks USING (cardid)
            WHERE deckid = $deck(deckid) AND mtime = 0 AND active = TRUE
            LIMIT $newlim
        }]
        set revcards [db eval {
            SELECT cardid,type FROM cards INNER JOIN carddecks USING (cardid)
            WHERE deckid = $deck(deckid) AND mtime != 0 AND mtime < $now
              AND active = TRUE
            LIMIT $revlim
        }]
        set newlim [/ [llength $newcards] 2]
        set revlim [/ [llength $revcards] 2]
        if {$newlim == 0 && $revlim == 0} {
            bail_out 0 "\033\[1\;1H\033\[2J$dname: no cards remain"
        }
        while {$newlim > 0 || $revlim > 0} {
            if {[rand_newreview $newlim $revlim]} {
                traincard newlim newcards 1
            } else {
                traincard revlim revcards 0
            }
        }
        set has_deck 1
    }
    if {$has_deck == 1} {tailcall traindeck $dname}
    bail_out 1 "krefu: no such deck '$dname'"
}

# routine for delaying showing the answer until the user hits some
# not-answer key (or to bail out or ignore the card right away)
proc wait_before_answer {} {
    global card db
    while 1 {
        switch [read stdin 1] {
            Q {bail_out}
            I {
                db eval {
                    UPDATE cards SET active = FALSE
                    WHERE cardid = $card(cardid)
                }
                return 0
            }
            \  -
            \n -
            \r {return 1}
        }
    }
}

set localize [file join $kdir krefu.tcl]
catch {source $localize} msg err
if {[dict get $err -code] != 0} {
    if {![string match "POSIX ENOENT *" [dict get $err -errorcode]]} {
        puts stderr "krefu: could not source $localize: $msg"
        exit 1
    }
}

main
