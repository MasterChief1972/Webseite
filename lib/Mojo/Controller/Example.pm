package Mojo::Controller::Example;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Digest::SHA qw(sha256_hex);
use POSIX       qw(strftime);

# =====================================================================
#  SEITEN ROUTEN
# =====================================================================

sub welcome  ($self) { $self->render(msg => 'Welcome to the Mojolicious real-time web framework!'); }
sub witze    ($self) { $self->render(template => 'example/Witze');    }
sub umfrage  ($self) { $self->render(template => 'example/Umfrage');  }
sub home     ($self) { $self->render(template => 'example/Home');     }
sub funktion ($self) { $self->render(template => 'example/Funktion'); }
sub buch     ($self) { $self->render(template => 'example/Buch');     }

# =====================================================================
#  DATENBANK
# =====================================================================

sub _db ($self) {
  state $sql;
  unless ($sql) {
    require Mojo::SQLite;
    $sql = Mojo::SQLite->new('sqlite:databank/buecherei.db');

    $sql->db->query(q{
      CREATE TABLE IF NOT EXISTS users (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        username      TEXT    NOT NULL UNIQUE COLLATE NOCASE,
        password_hash TEXT    NOT NULL,
        is_admin      INTEGER NOT NULL DEFAULT 0,
        firstname     TEXT    NOT NULL DEFAULT '',
        lastname      TEXT    NOT NULL DEFAULT '',
        created_at    INTEGER NOT NULL DEFAULT (strftime('%s','now'))
      )
    });

    # Spalten nachrüsten falls DB schon existiert
    eval { $sql->db->query("ALTER TABLE users ADD COLUMN is_admin  INTEGER NOT NULL DEFAULT 0") };
    eval { $sql->db->query("ALTER TABLE users ADD COLUMN firstname TEXT    NOT NULL DEFAULT ''") };
    eval { $sql->db->query("ALTER TABLE users ADD COLUMN lastname  TEXT    NOT NULL DEFAULT ''") };

    # Administrator immer Admin
    $sql->db->query(q{UPDATE users SET is_admin = 1 WHERE LOWER(username) = 'administrator'});

    $sql->db->query(q{
      CREATE TABLE IF NOT EXISTS loans (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id     TEXT    NOT NULL UNIQUE,
        user_id     INTEGER NOT NULL REFERENCES users(id),
        return_date TEXT    NOT NULL,
        borrowed_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
      )
    });

    $sql->db->query(q{
      CREATE TABLE IF NOT EXISTS borrow_counts (
        book_id TEXT    PRIMARY KEY,
        count   INTEGER NOT NULL DEFAULT 0
      )
    });

    $sql->db->query(q{
      CREATE TABLE IF NOT EXISTS book (
        id          TEXT PRIMARY KEY,
        title       TEXT NOT NULL,
        author      TEXT NOT NULL,
        genre       TEXT,
        rating      REAL DEFAULT 0,
        year        INTEGER,
        pages       INTEGER,
        isbn        TEXT,
        description TEXT,
        cover_url   TEXT,
        language    TEXT
      )
    });
    eval { $sql->db->query("ALTER TABLE book ADD COLUMN cover_url TEXT") };
    eval { $sql->db->query("ALTER TABLE book ADD COLUMN language  TEXT") };

    $sql->db->query(q{
      CREATE TABLE IF NOT EXISTS loan_history (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id     TEXT    NOT NULL,
        user_id     INTEGER NOT NULL REFERENCES users(id),
        return_date TEXT    NOT NULL,
        borrowed_at INTEGER NOT NULL,
        returned_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
      )
    });

    $sql->db->query(q{
      CREATE TABLE IF NOT EXISTS warnings (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id     INTEGER NOT NULL REFERENCES users(id),
        message     TEXT    NOT NULL,
        confirmed   INTEGER NOT NULL DEFAULT 0,
        created_at  INTEGER NOT NULL DEFAULT (strftime('%s','now'))
      )
    });

    # Sperrtabelle
    $sql->db->query(q{
      CREATE TABLE IF NOT EXISTS user_blocks (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id       INTEGER NOT NULL UNIQUE REFERENCES users(id),
        blocked_until TEXT    NOT NULL,
        reason        TEXT    NOT NULL DEFAULT '',
        created_at    INTEGER NOT NULL DEFAULT (strftime('%s','now'))
      )
    });

    # Ausleih-Einstellungen
    $sql->db->query(q{
      CREATE TABLE IF NOT EXISTS borrow_settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    });
    # Standardwerte setzen falls nicht vorhanden
    $sql->db->query(q{INSERT OR IGNORE INTO borrow_settings (key,value) VALUES ('max_books','3')});
    $sql->db->query(q{INSERT OR IGNORE INTO borrow_settings (key,value) VALUES ('max_days','30')});
    $sql->db->query(q{INSERT OR IGNORE INTO borrow_settings (key,value) VALUES ('min_days','1')});

    # Nutzungsbedingungen
    $sql->db->query(q{
      CREATE TABLE IF NOT EXISTS terms (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        version    TEXT    NOT NULL UNIQUE,
        content    TEXT    NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
      )
    });

    # Zustimmungen
    $sql->db->query(q{
      CREATE TABLE IF NOT EXISTS terms_acceptance (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id    INTEGER NOT NULL REFERENCES users(id),
        version    TEXT    NOT NULL,
        accepted_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        UNIQUE(user_id, version)
      )
    });
  }
  return $sql->db;
}

sub _hash ($self, $pw) {
  sha256_hex($pw . 'buecherei-geheim-2025');
}

sub _settings ($self) {
  my $rows = $self->_db->query('SELECT key, value FROM borrow_settings')->hashes->to_array;
  return { map { $_->{key} => $_->{value} } @$rows };
}

sub _me ($self) {
  my $uid = $self->session('user_id') or return undef;
  return $self->_db->query(
    'SELECT id, username, is_admin, firstname, lastname FROM users WHERE id = ?', $uid
  )->hash;
}

sub _require_login ($self) {
  my $user = $self->_me;
  unless ($user) {
    $self->render(json => { ok => 0, error => 'Nicht angemeldet.' }, status => 401);
    return undef;
  }
  return $user;
}

sub _require_admin ($self) {
  my $user = $self->_require_login or return undef;
  unless ($user->{is_admin}) {
    $self->render(json => { ok => 0, error => 'Kein Zugriff.' }, status => 403);
    return undef;
  }
  return $user;
}

# =====================================================================
#  AUTH
# =====================================================================

sub api_register ($self) {
  my $username      = $self->param('username')      // '';
  my $password      = $self->param('password')      // '';
  my $firstname     = $self->param('firstname')     // '';
  my $lastname      = $self->param('lastname')      // '';
  my $terms_version = $self->param('terms_version') // '';

  $username  =~ s/^\s+|\s+$//g;
  $firstname =~ s/^\s+|\s+$//g;
  $lastname  =~ s/^\s+|\s+$//g;

  return $self->render(json => { ok => 0, error => 'Vorname fehlt.' })        unless length($firstname) >= 1;
  return $self->render(json => { ok => 0, error => 'Nachname fehlt.' })       unless length($lastname)  >= 1;
  return $self->render(json => { ok => 0, error => 'Benutzername mindestens 2 Zeichen.' }) unless length($username) >= 2;
  return $self->render(json => { ok => 0, error => 'Passwort mindestens 4 Zeichen.' })    unless length($password) >= 4;

  # Pruefen ob aktuelle AGB existieren und ob zugestimmt wurde
  my $latest_terms = $self->_db->query('SELECT version FROM terms ORDER BY id DESC LIMIT 1')->hash;
  if ($latest_terms && !$terms_version) {
    return $self->render(json => { ok => 0, error => 'Bitte stimme den Nutzungsbedingungen zu.' });
  }

  my $exists = $self->_db->query('SELECT id FROM users WHERE username = ?', $username)->hash;
  return $self->render(json => { ok => 0, error => 'Benutzername bereits vergeben.' }) if $exists;

  my $user_id;
  eval {
    $self->_db->query(
      'INSERT INTO users (username, password_hash, firstname, lastname) VALUES (?,?,?,?)',
      $username, $self->_hash($password), $firstname, $lastname
    );
    $user_id = $self->_db->query('SELECT last_insert_rowid() AS id')->hash->{id};

    # Zustimmung direkt speichern
    if ($terms_version) {
      $self->_db->query(
        'INSERT OR IGNORE INTO terms_acceptance (user_id, version) VALUES (?,?)',
        $user_id, $terms_version
      );
    }
  };
  return $self->render(json => { ok => 0, error => 'Fehler beim Registrieren.' }) if $@;

  my $user = $self->_db->query(
    'SELECT id, username, is_admin, firstname, lastname FROM users WHERE username = ?', $username
  )->hash;
  $self->session(user_id => $user->{id});
  $self->render(json => {
    ok        => 1,
    username  => $user->{username},
    is_admin  => $user->{is_admin}  ? 1 : 0,
    firstname => $user->{firstname} // '',
    lastname  => $user->{lastname}  // '',
  });
}

sub api_login ($self) {
  my $username = $self->param('username') // '';
  my $password = $self->param('password') // '';

  my $user = $self->_db->query(
    'SELECT id, username, is_admin, firstname, lastname FROM users WHERE username = ? AND password_hash = ?',
    $username, $self->_hash($password)
  )->hash;

  unless ($user) {
    return $self->render(json => { ok => 0, error => 'Benutzername oder Passwort falsch.' });
  }

  $self->session(user_id => $user->{id});
  $self->render(json => {
    ok        => 1,
    username  => $user->{username},
    is_admin  => $user->{is_admin}  ? 1 : 0,
    firstname => $user->{firstname} // '',
    lastname  => $user->{lastname}  // '',
  });
}

sub api_logout ($self) {
  $self->session(expires => 1);
  $self->render(json => { ok => 1 });
}

sub api_me ($self) {
  my $user = $self->_me;
  unless ($user) {
    return $self->render(json => { ok => 0, error => 'Nicht angemeldet.' }, status => 401);
  }
  $self->render(json => {
    ok        => 1,
    username  => $user->{username},
    is_admin  => $user->{is_admin}  ? 1 : 0,
    firstname => $user->{firstname} // '',
    lastname  => $user->{lastname}  // '',
  });
}

# =====================================================================
#  BUECHER API
# =====================================================================

sub api_books ($self) {
  my $books = $self->_db->query(
    'SELECT id, title, author, genre, rating, year, pages, isbn, description, cover_url, language FROM book ORDER BY title'
  )->hashes->to_array;
  $self->render(json => { ok => 1, books => $books });
}

sub api_books_add ($self) {
  my $user   = $self->_require_admin or return;
  my $title     = $self->param('title')       // '';
  my $author    = $self->param('author')      // '';
  my $genre     = $self->param('genre')       // '';
  my $year      = $self->param('year')        // undef;
  my $pages     = $self->param('pages')       // undef;
  my $rating    = $self->param('rating')      // 0;
  my $isbn      = $self->param('isbn')        // '';
  my $language  = $self->param('language')    // '';
  my $desc      = $self->param('description') // '';
  my $cover_url = $self->param('cover_url')   // undef;

  $title  =~ s/^\s+|\s+$//g;
  $author =~ s/^\s+|\s+$//g;

  return $self->render(json => { ok => 0, error => 'Titel fehlt.' }) unless length($title)  >= 1;
  return $self->render(json => { ok => 0, error => 'Autor fehlt.' }) unless length($author) >= 1;

  my $max = $self->_db->query(
    q{SELECT id FROM book WHERE id LIKE 'b%' ORDER BY CAST(SUBSTR(id,2) AS INTEGER) DESC LIMIT 1}
  )->hash;
  my $new_id = ($max && $max->{id} =~ /^b(\d+)$/) ? 'b'.($1+1) : 'b0';

  $year   = undef unless $year      && $year      =~ /^\d+$/;
  $pages  = undef unless $pages     && $pages     =~ /^\d+$/;
  $rating = 0     unless $rating    && $rating    =~ /^[\d.]+$/;
  $cover_url = undef unless $cover_url && $cover_url =~ /^https?:\/\//;

  eval {
    $self->_db->query(
      'INSERT INTO book (id,title,author,genre,rating,year,pages,isbn,description,cover_url,language) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      $new_id, $title, $author, $genre, $rating, $year, $pages, $isbn, $desc, $cover_url, $language
    );
  };
  return $self->render(json => { ok => 0, error => 'Datenbankfehler: '.$@ }) if $@;
  $self->render(json => { ok => 1, book_id => $new_id });
}

sub api_books_update ($self) {
  my $user    = $self->_require_admin or return;
  my $book_id   = $self->param('book_id')      // '';
  my $title     = $self->param('title')        // '';
  my $author    = $self->param('author')       // '';
  my $genre     = $self->param('genre')        // '';
  my $year      = $self->param('year')         // undef;
  my $pages     = $self->param('pages')        // undef;
  my $rating    = $self->param('rating')       // 0;
  my $isbn      = $self->param('isbn')         // '';
  my $language  = $self->param('language')     // '';
  my $desc      = $self->param('description')  // '';
  my $cover_url = $self->param('cover_url')    // undef;

  return $self->render(json => { ok => 0, error => 'book_id fehlt.' }) unless $book_id;

  $year   = undef unless $year      && $year      =~ /^\d+$/;
  $pages  = undef unless $pages     && $pages     =~ /^\d+$/;
  $rating = 0     unless $rating    && $rating    =~ /^[\d.]+$/;
  $cover_url = undef unless $cover_url && $cover_url =~ /^https?:\/\//;

  eval {
    $self->_db->query(
      'UPDATE book SET title=?,author=?,genre=?,rating=?,year=?,pages=?,isbn=?,description=?,cover_url=?,language=? WHERE id=?',
      $title, $author, $genre, $rating, $year, $pages, $isbn, $desc, $cover_url, $language, $book_id
    );
  };
  return $self->render(json => { ok => 0, error => 'Datenbankfehler: '.$@ }) if $@;
  $self->render(json => { ok => 1 });
}

sub api_books_delete ($self) {
  my $user    = $self->_require_admin or return;
  my $book_id = $self->param('book_id') // '';
  return $self->render(json => { ok => 0, error => 'book_id fehlt.' }) unless $book_id;

  eval {
    $self->_db->query('DELETE FROM loans         WHERE book_id = ?', $book_id);
    $self->_db->query('DELETE FROM borrow_counts WHERE book_id = ?', $book_id);
    $self->_db->query('DELETE FROM loan_history  WHERE book_id = ?', $book_id);
    $self->_db->query('DELETE FROM book          WHERE id      = ?', $book_id);
  };
  return $self->render(json => { ok => 0, error => 'Datenbankfehler: '.$@ }) if $@;
  $self->render(json => { ok => 1 });
}

# =====================================================================
#  AUSLEIHEN API
# =====================================================================

sub api_loans ($self) {
  my $loans = $self->_db->query(q{
    SELECT l.book_id, u.username AS borrowed_by,
           l.return_date, l.borrowed_at, l.user_id
    FROM loans l JOIN users u ON u.id = l.user_id
  })->hashes->to_array;
  $self->render(json => { ok => 1, loans => $loans });
}

sub api_counts ($self) {
  my $rows   = $self->_db->query('SELECT book_id, count FROM borrow_counts ORDER BY count DESC')->hashes->to_array;
  my %counts = map { $_->{book_id} => $_->{count} } @$rows;
  $self->render(json => { ok => 1, counts => \%counts });
}

sub api_borrow ($self) {
  my $user        = $self->_require_login or return;
  my $book_id     = $self->param('book_id')     // '';
  my $return_date = $self->param('return_date') // '';

  # Gesperrten Nutzer prüfen
  my $block = $self->_db->query(
    "SELECT blocked_until FROM user_blocks WHERE user_id = ? AND blocked_until >= date('now')",
    $user->{id}
  )->hash;
  if ($block) {
    return $self->render(json => {
      ok    => 0,
      error => 'Dein Konto ist bis ' . $block->{blocked_until} . ' gesperrt. Du kannst keine Bücher ausleihen.'
    });
  }

  unless ($return_date =~ /^\d{4}-\d{2}-\d{2}$/) {
    return $self->render(json => { ok => 0, error => 'Ungültiges Datum.' });
  }

  my $today    = strftime('%Y-%m-%d', localtime);
  my $settings = $self->_settings;
  my $max_days = int($settings->{max_days} || 30);
  my $min_days = int($settings->{min_days} || 1);
  my $max_books= int($settings->{max_books}|| 3);

  if ($return_date le $today) {
    return $self->render(json => { ok => 0, error => 'Rückgabedatum muss in der Zukunft liegen.' });
  }

  # Max-Tage prüfen
  use POSIX qw(floor);
  my $diff_days = int((do {
    require Time::Piece;
    my $ret = Time::Piece->strptime($return_date, '%Y-%m-%d');
    my $tod = Time::Piece->strptime($today,       '%Y-%m-%d');
    ($ret - $tod) / 86400;
  }));
  if ($diff_days > $max_days) {
    return $self->render(json => {
      ok => 0, error => "Rückgabedatum darf maximal $max_days Tage in der Zukunft liegen."
    });
  }
  if ($diff_days < $min_days) {
    return $self->render(json => {
      ok => 0, error => "Rückgabedatum muss mindestens $min_days Tag(e) in der Zukunft liegen."
    });
  }

  # Max-Bücher prüfen
  my $user_loan_count = $self->_db->query(
    'SELECT COUNT(*) AS cnt FROM loans WHERE user_id = ?', $user->{id}
  )->hash->{cnt};
  if ($user_loan_count >= $max_books) {
    return $self->render(json => {
      ok => 0, error => "Du hast bereits $max_books Buch/Bücher ausgeliehen (Maximum erreicht)."
    });
  }

  my $existing = $self->_db->query('SELECT user_id FROM loans WHERE book_id = ?', $book_id)->hash;
  if ($existing) {
    my $owner = $self->_db->query('SELECT username FROM users WHERE id = ?', $existing->{user_id})->hash;
    return $self->render(json => { ok => 0, error => 'Bereits ausgeliehen von: '.($owner->{username}//'?') });
  }

  eval {
    $self->_db->query('INSERT INTO loans (book_id, user_id, return_date) VALUES (?,?,?)',
      $book_id, $user->{id}, $return_date);
    $self->_db->query(q{INSERT INTO borrow_counts (book_id, count) VALUES (?,1)
      ON CONFLICT(book_id) DO UPDATE SET count = count + 1}, $book_id);
  };
  return $self->render(json => { ok => 0, error => 'Datenbankfehler.' }) if $@;
  $self->render(json => { ok => 1 });
}

sub api_return ($self) {
  my $user    = $self->_require_login or return;
  my $book_id = $self->param('book_id') // '';

  my $loan = $self->_db->query('SELECT * FROM loans WHERE book_id = ?', $book_id)->hash;
  unless ($loan) {
    return $self->render(json => { ok => 0, error => 'Dieses Buch ist nicht ausgeliehen.' });
  }

  if ($loan->{user_id} != $user->{id} && !$user->{is_admin}) {
    my $owner = $self->_db->query('SELECT username FROM users WHERE id = ?', $loan->{user_id})->hash;
    return $self->render(json => { ok => 0, error => 'Nur "'.($owner->{username}//'?').'" kann dieses Buch zurückgeben.' });
  }

  eval {
    $self->_db->query(
      'INSERT INTO loan_history (book_id, user_id, return_date, borrowed_at) VALUES (?,?,?,?)',
      $loan->{book_id}, $loan->{user_id}, $loan->{return_date}, $loan->{borrowed_at}
    );
    $self->_db->query('DELETE FROM loans WHERE book_id = ?', $book_id);
  };
  return $self->render(json => { ok => 0, error => 'Datenbankfehler.' }) if $@;
  $self->render(json => { ok => 1 });
}

# =====================================================================
#  ADMIN API
# =====================================================================

sub api_admin_history ($self) {
  my $user = $self->_require_admin or return;

  my $current = $self->_db->query(q{
    SELECT b.title, b.id AS book_id, u.username AS borrowed_by,
           u.firstname, u.lastname,
           l.return_date,
           datetime(l.borrowed_at,'unixepoch','localtime') AS borrowed_at,
           'aktiv' AS status
    FROM loans l
    JOIN users u ON u.id = l.user_id
    LEFT JOIN book b ON b.id = l.book_id
    ORDER BY l.borrowed_at DESC
  })->hashes->to_array;

  my $past = $self->_db->query(q{
    SELECT b.title, h.book_id, u.username AS borrowed_by,
           u.firstname, u.lastname,
           h.return_date,
           datetime(h.borrowed_at,'unixepoch','localtime') AS borrowed_at,
           datetime(h.returned_at,'unixepoch','localtime') AS returned_at,
           'zurueckgegeben' AS status
    FROM loan_history h
    JOIN users u ON u.id = h.user_id
    LEFT JOIN book b ON b.id = h.book_id
    ORDER BY h.returned_at DESC
    LIMIT 200
  })->hashes->to_array;

  my $users = $self->_db->query(q{
    SELECT u.id, u.username, u.is_admin, u.firstname, u.lastname,
           datetime(u.created_at,'unixepoch','localtime') AS created_at,
           ub.blocked_until
    FROM users u
    LEFT JOIN user_blocks ub ON ub.user_id = u.id
      AND ub.blocked_until >= date('now')
    ORDER BY u.created_at DESC
  })->hashes->to_array;

  $self->render(json => { ok => 1, current => $current, past => $past, users => $users });
}

sub api_admin_book_history ($self) {
  my $user    = $self->_require_admin or return;
  my $book_id = $self->param('book_id') // '';

  my $current = $self->_db->query(q{
    SELECT u.username AS borrowed_by, l.return_date,
           datetime(l.borrowed_at,'unixepoch','localtime') AS borrowed_at,
           'aktiv' AS status
    FROM loans l JOIN users u ON u.id = l.user_id
    WHERE l.book_id = ?
  }, $book_id)->hashes->to_array;

  my $past = $self->_db->query(q{
    SELECT u.username AS borrowed_by, h.return_date,
           datetime(h.borrowed_at,'unixepoch','localtime') AS borrowed_at,
           datetime(h.returned_at,'unixepoch','localtime') AS returned_at,
           'zurueckgegeben' AS status
    FROM loan_history h JOIN users u ON u.id = h.user_id
    WHERE h.book_id = ?
    ORDER BY h.returned_at DESC
  }, $book_id)->hashes->to_array;

  $self->render(json => { ok => 1, current => $current, past => $past });
}

sub api_admin_toggle ($self) {
  my $admin   = $self->_require_admin or return;
  my $user_id = $self->param('user_id') // '';

  unless ($user_id =~ /^\d+$/) {
    return $self->render(json => { ok => 0, error => 'Ungültige user_id.' });
  }
  if ($user_id == $admin->{id}) {
    return $self->render(json => { ok => 0, error => 'Du kannst dir selbst den Admin-Status nicht entziehen.' });
  }

  my $target = $self->_db->query('SELECT id, is_admin FROM users WHERE id = ?', $user_id)->hash;
  unless ($target) {
    return $self->render(json => { ok => 0, error => 'Nutzer nicht gefunden.' });
  }

  my $new_status = $target->{is_admin} ? 0 : 1;
  $self->_db->query('UPDATE users SET is_admin = ? WHERE id = ?', $new_status, $user_id);
  $self->render(json => { ok => 1, is_admin => $new_status });
}

# =====================================================================
#  VERWARNUNGEN API
# =====================================================================

sub api_admin_warn ($self) {
  my $admin    = $self->_require_admin or return;
  my $username = $self->param('username') // '';
  my $message  = $self->param('message')  // '';
  $message =~ s/^\s+|\s+$//g;

  return $self->render(json => { ok => 0, error => 'Nachricht fehlt.' }) unless length($message) >= 1;

  my $user = $self->_db->query('SELECT id FROM users WHERE username = ?', $username)->hash;
  return $self->render(json => { ok => 0, error => 'Nutzer nicht gefunden.' }) unless $user;

  $self->_db->query('DELETE FROM warnings WHERE user_id = ? AND confirmed = 0', $user->{id});
  $self->_db->query('INSERT INTO warnings (user_id, message) VALUES (?,?)', $user->{id}, $message);
  $self->render(json => { ok => 1 });
}

sub api_warn_check ($self) {
  my $user = $self->_require_login or return;
  my $warn = $self->_db->query(
    'SELECT message FROM warnings WHERE user_id = ? AND confirmed = 0 ORDER BY created_at DESC LIMIT 1',
    $user->{id}
  )->hash;
  $self->render(json => { ok => 1, warning => $warn ? $warn->{message} : undef });
}

# GET /api/block/check - Sperre pruefen
sub api_block_check ($self) {
  my $user = $self->_require_login or return;

  my $block = $self->_db->query(
    "SELECT blocked_until, reason FROM user_blocks WHERE user_id = ? AND blocked_until >= date('now')",
    $user->{id}
  )->hash;

  unless ($block) {
    return $self->render(json => { ok => 1, blocked => 0 });
  }

  $self->render(json => {
    ok            => 1,
    blocked       => 1,
    blocked_until => $block->{blocked_until},
    reason        => $block->{reason} // '',
  });
}

sub api_warn_confirm ($self) {
  my $user = $self->_require_login or return;
  $self->_db->query('UPDATE warnings SET confirmed = 1 WHERE user_id = ? AND confirmed = 0', $user->{id});
  $self->render(json => { ok => 1 });
}

# =====================================================================
#  PROFIL API
# =====================================================================

sub api_profile_update_name ($self) {
  my $user      = $self->_require_login or return;
  my $firstname = $self->param('firstname') // '';
  my $lastname  = $self->param('lastname')  // '';
  $firstname =~ s/^\s+|\s+$//g;
  $lastname  =~ s/^\s+|\s+$//g;

  return $self->render(json => { ok => 0, error => 'Vorname fehlt.' })  unless length($firstname) >= 1;
  return $self->render(json => { ok => 0, error => 'Nachname fehlt.' }) unless length($lastname)  >= 1;

  $self->_db->query('UPDATE users SET firstname=?, lastname=? WHERE id=?', $firstname, $lastname, $user->{id});
  $self->render(json => { ok => 1 });
}

sub api_profile_delete ($self) {
  my $user = $self->_require_login or return;

  if ($user->{is_admin}) {
    return $self->render(json => { ok => 0, error => 'Administratoren können ihr Konto nicht löschen.' });
  }

  my $password = $self->param('password') // '';
  my $check = $self->_db->query(
    'SELECT id FROM users WHERE id = ? AND password_hash = ?',
    $user->{id}, $self->_hash($password)
  )->hash;
  return $self->render(json => { ok => 0, error => 'Falsches Passwort.' }) unless $check;

  eval {
    my $loans = $self->_db->query('SELECT * FROM loans WHERE user_id = ?', $user->{id})->hashes->to_array;
    for my $loan (@$loans) {
      $self->_db->query(
        'INSERT INTO loan_history (book_id, user_id, return_date, borrowed_at) VALUES (?,?,?,?)',
        $loan->{book_id}, $loan->{user_id}, $loan->{return_date}, $loan->{borrowed_at}
      );
    }
    $self->_db->query('DELETE FROM loans    WHERE user_id = ?', $user->{id});
    $self->_db->query('DELETE FROM warnings WHERE user_id = ?', $user->{id});
    $self->_db->query('DELETE FROM users    WHERE id      = ?', $user->{id});
  };
  return $self->render(json => { ok => 0, error => 'Datenbankfehler.' }) if $@;

  $self->session(expires => 1);
  $self->render(json => { ok => 1 });
}

# =====================================================================
#  NUTZER SPERREN API
# =====================================================================

sub api_admin_block_user ($self) {
  my $admin   = $self->_require_admin or return;
  my $user_id = $self->param('user_id') // '';
  my $days    = $self->param('days')    // 0;
  my $reason  = $self->param('reason')  // '';

  unless ($user_id =~ /^\d+$/ && $days >= 1) {
    return $self->render(json => { ok => 0, error => 'Ungültige Parameter.' });
  }
  if ($user_id == $admin->{id}) {
    return $self->render(json => { ok => 0, error => 'Du kannst dich nicht selbst sperren.' });
  }

  my $target = $self->_db->query('SELECT id, is_admin FROM users WHERE id = ?', $user_id)->hash;
  return $self->render(json => { ok => 0, error => 'Nutzer nicht gefunden.' }) unless $target;

  if ($target->{is_admin}) {
    return $self->render(json => { ok => 0, error => 'Administratoren können nicht gesperrt werden.' });
  }

  eval {
    $self->_db->query(q{
      INSERT INTO user_blocks (user_id, blocked_until, reason)
      VALUES (?, date('now', ? || ' days'), ?)
      ON CONFLICT(user_id) DO UPDATE SET
        blocked_until = date('now', ? || ' days'),
        reason = ?,
        created_at = strftime('%s','now')
    }, $user_id, "+$days", $reason, "+$days", $reason);
  };
  return $self->render(json => { ok => 0, error => 'Datenbankfehler: ' . $@ }) if $@;
  $self->render(json => { ok => 1 });
}

sub api_admin_unblock_user ($self) {
  my $admin   = $self->_require_admin or return;
  my $user_id = $self->param('user_id') // '';

  unless ($user_id =~ /^\d+$/) {
    return $self->render(json => { ok => 0, error => 'Ungültige user_id.' });
  }

  $self->_db->query('DELETE FROM user_blocks WHERE user_id = ?', $user_id);
  $self->render(json => { ok => 1 });
}

# POST /api/admin/reset_counts - Top3 Zaehler zuruecksetzen
sub api_admin_reset_counts ($self) {
  my $admin = $self->_require_admin or return;
  $self->_db->query('DELETE FROM borrow_counts');
  $self->render(json => { ok => 1 });
}

# =====================================================================
#  PASSWORT ZURÜCKSETZEN & ADMIN NUTZER LÖSCHEN
# =====================================================================

# POST /api/auth/reset_password - Passwort zurücksetzen (kein Login nötig)
sub api_reset_password ($self) {
  my $username     = $self->param('username')     // '';
  my $new_password = $self->param('new_password') // '';

  $username =~ s/^\s+|\s+$//g;

  unless (length($username) >= 1) {
    return $self->render(json => { ok => 0, error => 'Benutzername fehlt.' });
  }
  unless (length($new_password) >= 4) {
    return $self->render(json => { ok => 0, error => 'Passwort mindestens 4 Zeichen.' });
  }

  my $user = $self->_db->query('SELECT id FROM users WHERE username = ?', $username)->hash;
  unless ($user) {
    return $self->render(json => { ok => 0, error => 'Benutzername nicht gefunden.' });
  }

  $self->_db->query(
    'UPDATE users SET password_hash = ? WHERE id = ?',
    $self->_hash($new_password), $user->{id}
  );

  $self->render(json => { ok => 1 });
}

# POST /api/admin/delete_user - Nutzer löschen (nur Administrator)
sub api_admin_delete_user ($self) {
  my $admin   = $self->_require_admin or return;
  my $user_id = $self->param('user_id') // '';

  unless ($user_id =~ /^\d+$/) {
    return $self->render(json => { ok => 0, error => 'Ungültige user_id.' });
  }
  if ($user_id == $admin->{id}) {
    return $self->render(json => { ok => 0, error => 'Du kannst dich nicht selbst löschen.' });
  }

  my $target = $self->_db->query('SELECT id, is_admin FROM users WHERE id = ?', $user_id)->hash;
  unless ($target) {
    return $self->render(json => { ok => 0, error => 'Nutzer nicht gefunden.' });
  }
  if ($target->{is_admin}) {
    return $self->render(json => { ok => 0, error => 'Administratoren können nicht gelöscht werden.' });
  }

  eval {
    # Aktive Ausleihen in Historie verschieben
    my $loans = $self->_db->query('SELECT * FROM loans WHERE user_id = ?', $user_id)->hashes->to_array;
    for my $loan (@$loans) {
      $self->_db->query(
        'INSERT INTO loan_history (book_id, user_id, return_date, borrowed_at) VALUES (?,?,?,?)',
        $loan->{book_id}, $loan->{user_id}, $loan->{return_date}, $loan->{borrowed_at}
      );
    }
    $self->_db->query('DELETE FROM loans       WHERE user_id = ?', $user_id);
    $self->_db->query('DELETE FROM warnings    WHERE user_id = ?', $user_id);
    $self->_db->query('DELETE FROM user_blocks WHERE user_id = ?', $user_id);
    $self->_db->query('DELETE FROM users       WHERE id      = ?', $user_id);
  };
  return $self->render(json => { ok => 0, error => 'Datenbankfehler.' }) if $@;

  $self->render(json => { ok => 1 });
}


# =====================================================================
#  NUTZUNGSBEDINGUNGEN API
# =====================================================================

# GET /api/terms - aktuelle Nutzungsbedingungen laden (oeffentlich)
sub api_terms ($self) {
  my $terms = $self->_db->query(q{
    SELECT version, content,
           datetime(created_at,'unixepoch','localtime') AS updated_at
    FROM terms ORDER BY id DESC LIMIT 1
  })->hash;

  unless ($terms) {
    return $self->render(json => {
      ok      => 1,
      version => undef,
      content => 'Es wurden noch keine Nutzungsbedingungen hinterlegt.',
      updated_at => ''
    });
  }

  $self->render(json => {
    ok         => 1,
    version    => $terms->{version},
    content    => $terms->{content},
    updated_at => $terms->{updated_at} // '',
  });
}

# POST /api/terms/accept - Nutzungsbedingungen zustimmen
sub api_terms_accept ($self) {
  my $user    = $self->_require_login or return;
  my $version = $self->param('version') // '';

  return $self->render(json => { ok => 0, error => 'Version fehlt.' }) unless $version;

  eval {
    $self->_db->query(q{
      INSERT INTO terms_acceptance (user_id, version)
      VALUES (?, ?)
      ON CONFLICT(user_id, version) DO UPDATE SET accepted_at = strftime('%s','now')
    }, $user->{id}, $version);
  };
  return $self->render(json => { ok => 0, error => 'Fehler.' }) if $@;
  $self->render(json => { ok => 1 });
}

# GET /api/terms/check - pruefen ob Nutzer aktuellen Bedingungen zugestimmt hat
sub api_terms_check ($self) {
  my $user = $self->_require_login or return;

  my $latest = $self->_db->query(
    'SELECT version FROM terms ORDER BY id DESC LIMIT 1'
  )->hash;

  unless ($latest) {
    return $self->render(json => { ok => 1, needs_acceptance => 0 });
  }

  my $accepted = $self->_db->query(
    'SELECT id FROM terms_acceptance WHERE user_id = ? AND version = ?',
    $user->{id}, $latest->{version}
  )->hash;

  $self->render(json => {
    ok               => 1,
    needs_acceptance => $accepted ? 0 : 1,
    version          => $latest->{version},
  });
}

# POST /api/admin/terms/save - Nutzungsbedingungen speichern (nur Administrator)
sub api_admin_terms_save ($self) {
  my $admin   = $self->_require_admin or return;
  my $version = $self->param('version') // '';
  my $content = $self->param('content') // '';

  $version =~ s/^\s+|\s+$//g;
  $content =~ s/^\s+|\s+$//g;

  return $self->render(json => { ok => 0, error => 'Version fehlt.' }) unless length($version) >= 1;
  return $self->render(json => { ok => 0, error => 'Inhalt fehlt.' })  unless length($content) >= 1;

  eval {
    $self->_db->query(
      'INSERT OR REPLACE INTO terms (version, content) VALUES (?, ?)',
      $version, $content
    );
  };
  return $self->render(json => { ok => 0, error => 'Datenbankfehler.' }) if $@;
  $self->render(json => { ok => 1 });
}


# GET /api/admin/terms/stats - Zustimmungsstatistik (nur Administrator)
sub api_admin_terms_stats ($self) {
  my $admin = $self->_require_admin or return;

  my $latest = $self->_db->query(
    q{SELECT version, content, datetime(created_at,'unixepoch','localtime') AS updated_at
      FROM terms ORDER BY id DESC LIMIT 1}
  )->hash;

  unless ($latest) {
    return $self->render(json => { ok => 1, version => undef });
  }

  # Alle Nutzer (ohne Admins)
  my $users = $self->_db->query(
    'SELECT id, username, firstname, lastname FROM users WHERE is_admin = 0'
  )->hashes->to_array;

  # Wer hat zugestimmt?
  my $accepted_ids = $self->_db->query(
    'SELECT user_id FROM terms_acceptance WHERE version = ?', $latest->{version}
  )->arrays->to_array;
  my %accepted_set = map { $_->[0] => 1 } @$accepted_ids;

  my @pending = grep { !$accepted_set{$_->{id}} } @$users;

  $self->render(json => {
    ok           => 1,
    version      => $latest->{version},
    updated_at   => $latest->{updated_at} // '',
    total_users  => scalar(@$users),
    accepted     => scalar(keys %accepted_set),
    pending_users => \@pending,
  });
}


# =====================================================================
#  AUSLEIH-EINSTELLUNGEN API
# =====================================================================

# GET /api/admin/settings
sub api_admin_settings ($self) {
  my $user = $self->_require_admin or return;
  my $s    = $self->_settings;
  $self->render(json => {
    ok        => 1,
    max_books => int($s->{max_books} || 3),
    max_days  => int($s->{max_days}  || 30),
    min_days  => int($s->{min_days}  || 1),
  });
}

# POST /api/admin/settings/save
sub api_admin_settings_save ($self) {
  my $admin     = $self->_require_admin or return;
  my $max_books = $self->param('max_books') // 3;
  my $max_days  = $self->param('max_days')  // 30;
  my $min_days  = $self->param('min_days')  // 1;

  $max_books = int($max_books); $max_days = int($max_days); $min_days = int($min_days);

  return $self->render(json => { ok => 0, error => 'Ungültige Werte.' })
    unless $max_books >= 1 && $max_days >= 1 && $min_days >= 1 && $min_days <= $max_days;

  $self->_db->query("INSERT OR REPLACE INTO borrow_settings (key,value) VALUES ('max_books',?)", $max_books);
  $self->_db->query("INSERT OR REPLACE INTO borrow_settings (key,value) VALUES ('max_days',?)",  $max_days);
  $self->_db->query("INSERT OR REPLACE INTO borrow_settings (key,value) VALUES ('min_days',?)",  $min_days);

  $self->render(json => { ok => 1 });
}

# GET /api/settings (public - for borrow form date limits)
sub api_settings ($self) {
  my $s = $self->_settings;
  $self->render(json => {
    ok        => 1,
    max_books => int($s->{max_books} || 3),
    max_days  => int($s->{max_days}  || 30),
    min_days  => int($s->{min_days}  || 1),
  });
}


1;