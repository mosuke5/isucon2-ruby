require 'sinatra/base'
require 'slim'
require 'json'
require 'mysql2'

class Isucon2App < Sinatra::Base
  $stdout.sync = true
  set :slim, :pretty => true, :layout => true

  configure do
    config = JSON.parse(IO.read(File.dirname(__FILE__) + "/../config/common.#{ ENV['ISUCON_ENV'] || 'local' }.json"))['database']
    $mysql = Mysql2::Client.new(
        :host => config['host'],
        :port => config['port'],
        :username => config['username'],
        :password => config['password'],
        :database => config['dbname'],
        :reconnect => true,
      )
  end

  helpers do
    def recent_sold
      $mysql.query(
        'SELECT stock.seat_id, variation.name AS v_name, ticket.name AS t_name, artist.name AS a_name FROM stock
           JOIN variation ON stock.variation_id = variation.id
           JOIN ticket ON variation.ticket_id = ticket.id
           JOIN artist ON ticket.artist_id = artist.id
         WHERE member_id IS NOT NULL
         ORDER BY member_id DESC LIMIT 10',
      )
    end
  end

  # main

  get '/' do
    artists = $mysql.query("SELECT * FROM artist ORDER BY id")
    slim :index, :locals => {
      :artists => artists,
    }
  end

  get '/artist/:artistid' do
    artist  = $mysql.query(
      "SELECT id, name FROM artist WHERE id = #{ $mysql.escape(params[:artistid]) } LIMIT 1",
    ).first
    tickets = $mysql.query(
      "SELECT id, name FROM ticket WHERE artist_id = #{ $mysql.escape(artist['id'].to_s) } ORDER BY id",
    )
    tickets.each do |ticket|
      ticket["count"] = $mysql.query(
        "SELECT COUNT(*) AS cnt FROM variation
         INNER JOIN stock ON stock.variation_id = variation.id
         WHERE variation.ticket_id = #{ $mysql.escape(ticket['id'].to_s) } AND stock.member_id IS NULL",
      ).first["cnt"]
    end
    slim :artist, :locals => {
      :artist  => artist,
      :tickets => tickets,
    }
  end

  get '/ticket/:ticketid' do
    ticket = $mysql.query(
      "SELECT t.*, a.name AS artist_name FROM ticket t
       INNER JOIN artist a ON t.artist_id = a.id
       WHERE t.id = #{ $mysql.escape(params[:ticketid]) } LIMIT 1",
    ).first
    variations = $mysql.query(
      "SELECT id, name FROM variation WHERE ticket_id = #{ $mysql.escape(ticket['id'].to_s) } ORDER BY id",
    )
    variations.each do |variation|
      variation["count"] = $mysql.query(
        "SELECT COUNT(*) AS cnt FROM stock
         WHERE variation_id = #{ $mysql.escape(variation['id'].to_s) } AND member_id IS NULL",
      ).first["cnt"]
      variation["stock"] = {}
      $mysql.query(
        "SELECT seat_id, member_id FROM stock
         WHERE variation_id = #{ $mysql.escape(variation['id'].to_s) }",
      ).each do |stock|
        variation["stock"][stock["seat_id"]] = stock["member_id"]
      end
    end
    slim :ticket, :locals => {
      :ticket     => ticket,
      :variations => variations,
    }
  end

  post '/buy' do
    $mysql.query('BEGIN')
    #$mysql.query("INSERT INTO order_request (member_id) VALUES ('#{ $mysql.escape(params[:member_id]) }')")
    #order_id = $mysql.last_id
    puts ("UPDATE stock SET member_id = '#{ $mysql.escape(params[:member_id].to_s) }'
       WHERE variation_id = #{ $mysql.escape(params[:variation_id]) } AND member_id IS NULL
       ORDER BY RAND() LIMIT 1")
    $mysql.query(
      "UPDATE stock SET member_id = '#{ $mysql.escape(params[:member_id].to_s) }'
       WHERE variation_id = #{ $mysql.escape(params[:variation_id]) } AND member_id IS NULL
       ORDER BY RAND() LIMIT 1",
    )
    if $mysql.affected_rows > 0
      seat_id = $mysql.query(
        "SELECT seat_id FROM stock WHERE member_id = '#{ $mysql.escape(params[:member_id].to_s) }' LIMIT 1",
      ).first['seat_id']
      $mysql.query('COMMIT')
      slim :complete, :locals => { :seat_id => seat_id, :member_id => params[:member_id] }
    else
      $mysql.query('ROLLBACK')
      slim :soldout
    end
  end

  # admin

  get '/admin' do
    slim :admin
  end

  get '/admin/order.csv' do
    body  = ''
    orders = $mysql.query(
      'SELECT stock.member_id, stock.seat_id, stock.variation_id, stock.updated_at FROM stock'
    )
    orders.each do |order|
      order['updated_at'] = order['updated_at'].strftime('%Y-%m-%d %X')
      body += order.values_at('id', 'member_id', 'seat_id', 'variation_id', 'updated_at').join(',')
      body += "\n"
    end
    [200, { 'Content-Type' => 'text/csv' }, body]
  end

  post '/admin' do
    open(File.dirname(__FILE__) + '/../config/database/initial_data.sql') do |file|
      file.each do |line|
        next unless line.strip!.length > 0
        $mysql.query(line)
      end
    end
    redirect '/admin', 302
  end

  run! if app_file == $0
end
