package Mojo;
use Mojo::Base 'Mojolicious', -signatures;


sub startup ($self) {

  my $config = $self->plugin('NotYAMLConfig');
  $self->secrets($config->{secrets});

  # Controller-Namespace explizit setzen
  $self->routes->namespaces(['Mojo::Controller']);

  my $r = $self->routes;

  # Seiten
  $r->get('/')->to('Example#welcome');
  $r->get('/Witze')->to('Example#witze');
  $r->get('/Umfrage')->to('Example#umfrage');
  $r->get('/Home')->to('Example#home');
  $r->get('/Funktion')->to('Example#funktion');
  $r->get('/Buch')->to('Example#buch');

  # Auth API
  $r->post('/api/register')->to('Example#api_register');
  $r->post('/api/login')->to('Example#api_login');
  $r->post('/api/logout')->to('Example#api_logout');
  $r->get('/api/me')->to('Example#api_me');

  # Ausleihen API
  $r->get('/api/loans')->to('Example#api_loans');
  $r->get('/api/counts')->to('Example#api_counts');
  $r->post('/api/borrow')->to('Example#api_borrow');
  $r->post('/api/return')->to('Example#api_return');

  # Buecher API
  $r->get('/api/books')->to('Example#api_books');
  $r->post('/api/books/add')->to('Example#api_books_add');
  $r->post('/api/books/update')->to('Example#api_books_update');
  $r->post('/api/books/delete')->to('Example#api_books_delete');

  # Admin API
  $r->get('/api/admin/history')->to('Example#api_admin_history');
  $r->get('/api/admin/book_history/:book_id')->to('Example#api_admin_book_history');
  $r->post('/api/admin/warn')->to('Example#api_admin_warn');
  $r->post('/api/admin/toggle_admin')->to('Example#api_admin_toggle');
  $r->post('/api/admin/block_user')->to('Example#api_admin_block_user');
  $r->post('/api/admin/unblock_user')->to('Example#api_admin_unblock_user');
  $r->post('/api/admin/reset_counts')->to('Example#api_admin_reset_counts');

  # Verwarnungen
  $r->get('/api/warn/check')->to('Example#api_warn_check');
  $r->get('/api/block/check')->to('Example#api_block_check');
  $r->post('/api/warn/confirm')->to('Example#api_warn_confirm');

  # Profil
  $r->post('/api/profile/update_name')->to('Example#api_profile_update_name');
  $r->post('/api/profile/delete')->to('Example#api_profile_delete');

  # Passwort zurücksetzen (öffentlich)
  $r->post('/api/auth/reset_password')->to('Example#api_reset_password');

  # Admin Nutzer löschen
  $r->post('/api/admin/delete_user')->to('Example#api_admin_delete_user');

  # Nutzungsbedingungen
  $r->get('/api/terms')->to('Example#api_terms');
  $r->post('/api/terms/accept')->to('Example#api_terms_accept');
  $r->get('/api/terms/check')->to('Example#api_terms_check');
  $r->post('/api/admin/terms/save')->to('Example#api_admin_terms_save');
  $r->get('/api/admin/terms/stats')->to('Example#api_admin_terms_stats');

  # Ausleih-Einstellungen
  $r->get('/api/admin/settings')->to('Example#api_admin_settings');
  $r->post('/api/admin/settings/save')->to('Example#api_admin_settings_save');
  $r->get('/api/settings')->to('Example#api_settings');
}


1;