require 'socket'

# Websocket server library
require 'em-websocket'

# JSON parsing
require 'json'

# Load the database configuration
require_relative '../database_config'

require_relative '../../app/models/match'

# Proxy to connect to the dealer
require_relative '../web_application_player_proxy'
require 'acpc_poker_types'
require 'acpc_dealer'

# For an opponent bot
require 'process_runner'

require_relative 'worker_helpers'

# Email on error
require_relative 'setup_rusen'

# Easier logging
require_relative '../simple_logging'
using SimpleLogging::MessageFormatting

require_relative '../application_defs'

module AcpcPokerGuiClient
class TableManager
  include WorkerHelpers
  include AcpcPokerTypes
  include SimpleLogging

  DEALER_HOST = Socket.gethostname

  def self.listen_to_gui(authorized_client_origin)
    new(authorized_client_origin).listen_to_gui
  end

  def initialize(authorized_client_origin)
    @table_information = {}
    @authorized_client_origin = authorized_client_origin
    @logger = Logger.from_file_name(File.join(ApplicationDefs::LOG_DIRECTORY, 'table_manager.log')).with_metadata!
  end

  def listen_to_gui
    EventMachine::WebSocket.start(:host => "0.0.0.0", :port => ApplicationDefs::WEBSOCKET_PORT) do |connection_to_browser|
      connection_to_browser.onopen do |handshake|
        log "#{__method__}: onopen", origin: handshake.origin

        connection_to_browser.close unless handshake.origin == @authorized_client_origin
      end
      connection_to_browser.onclose do |handshake|
        log "#{__method__}: onclose", handshake: handshake
      end
      connection_to_browser.onmessage do |msg|
        Thread.new do
          log "#{__method__}: onmessage", msg: msg

          params = JSON.parse(msg)

          log "#{__method__}: onmessage", params: params

          ->(&block) { block.call match_instance(params.retrieve_match_id_or_raise_exception) }.call do |match|
            case params[ApplicationDefs::REQUEST_KEY]
            when ApplicationDefs::START_MATCH_REQUEST_CODE
              start_dealer!(params, match)

              opponents = []
              match.every_bot(DEALER_HOST) do |bot_command|
                opponents << bot_command
              end

              start_opponents!(opponents).start_proxy!(match, connection_to_browser)
            when ApplicationDefs::START_PROXY_REQUEST_CODE
              start_proxy! match, connection_to_browser
            when ApplicationDefs::PLAY_ACTION_REQUEST_CODE
              play! params, match, connection_to_browser
            else
              raise "Unrecognized request: #{params[ApplicationDefs::REQUEST_KEY]}"
            end
          end
        end
      end
      connection_to_browser.onerror do |e|
        error = {error: {message: e.message, backtrace: e.backtrace}}
        log "#{__method__}: onerror", error, Logger::Severity::ERROR
        connection_to_browser.send error.to_json unless e.kind_of?(EM::WebSocket::WebSocketError) # Notify the GUI
        Rusen.notify e # Send an email notification
      end

      yield if block_given?
    end
  end

  def start_dealer!(params, match)
    log __method__, params: params

    # Clean up data from dead matches
    @table_information.each do |match_id, match_processes|
      unless match_processes[:dealer] && match_processes[:dealer][:pid] && match_processes[:dealer][:pid].process_exists?
        log __method__, msg: "Deleting background processes with match ID #{match_id}"
        @table_information.delete(match_id)
      end
    end

    dealer_arguments = {
      match_name: match.name,
      game_def_file_name: match.game_definition_file_name,
      hands: match.number_of_hands,
      random_seed: match.random_seed.to_s,
      player_names: match.player_names.join(' '),
      options: (params['options'] || {})
    }
    log_directory = params['log_directory']

    match_processes = @table_information[match.id] || {}

    log __method__, {
      match_id: match.id,
      dealer_arguments: dealer_arguments,
      log_directory: log_directory,
      num_tables: @table_information.length
    }

    dealer_information = match_processes[:dealer] || {}

    return self if dealer_information[:pid] && dealer_information[:pid].process_exists? # The dealer is already started

    # Start the dealer
    begin
      dealer_information = AcpcDealer::DealerRunner.start(
        dealer_arguments,
        log_directory
      )
      match_processes[:dealer] = dealer_information
      @table_information[match.id] = match_processes
    rescue => unable_to_start_dealer_exception
      handle_exception match.id, "unable to start dealer: #{unable_to_start_dealer_exception.message}"
      raise unable_to_start_dealer_exception
    end

    # Get the player port numbers
    begin
      port_numbers = dealer_information[:port_numbers]

      # Store the port numbers in the database so the web app can access them
      match.port_numbers = port_numbers

      save_match_instance match
    rescue => unable_to_retrieve_port_numbers_from_dealer_exception
      handle_exception match.id, "unable to retrieve player port numbers from the dealer: #{unable_to_retrieve_port_numbers_from_dealer_exception.message}"
      raise unable_to_retrieve_port_numbers_from_dealer_exception
    end

    self
  end

  def start_opponents!(bot_start_commands)
    bot_start_commands.each do |bot_start_command|
      start_opponent! bot_start_command
    end

    self
  end

  def start_opponent!(bot_start_command)
    log __method__, bot_start_command: bot_start_command

    begin
      ProcessRunner.go bot_start_command
    rescue => unable_to_start_bot_exception
      handle_exception match_id, "unable to start bot with command \"#{bot_start_command}\": #{unable_to_start_bot_exception.message}"
      raise unable_to_start_bot_exception
    end

    self
  end

  def start_proxy!(match, connection_to_browser)
    match_processes = @table_information[match.id] || {}
    proxy = match_processes[:proxy]

    log __method__, {
      match_id: match.id,
      num_tables: @table_information.length,
      num_match_processes: match_processes.length,
      proxy_present: !proxy.nil?
    }

    return self if proxy

    begin
      game_definition = GameDefinition.parse_file(match.game_definition_file_name)
      # Store some necessary game definition properties in the database so the web app can access
      # them without parsing the game definition itself
      match.betting_type = game_definition.betting_type
      match.number_of_hole_cards = game_definition.number_of_hole_cards
      match.min_wagers = game_definition.min_wagers
      match.blinds = game_definition.blinds
      save_match_instance match

      proxy = WebApplicationPlayerProxy.new(
        match.id,
        AcpcDealer::ConnectionInformation.new(
          match.port_numbers[match.seat - 1],
          DEALER_HOST
        ),
        match.seat - 1,
        game_definition,
        match.player_names.join(' '),
        match.number_of_hands
      ) do |players_at_the_table|

        log "#{__method__}: Initializing proxy", {
          match_id: match.id,
          at_least_one_state: !players_at_the_table.transition.next_state.nil?
        }
        connection_to_browser.send({
          reply: ApplicationDefs::START_PROXY_REQUEST_CODE,
          match_id: match.id
        }.to_json)
      end
    rescue => e
      handle_exception match.id, "unable to start the user's proxy: #{e.message}"
      raise e
    end

    log "#{__method__}: After starting proxy", {
      match_id: match.id,
      proxy_present: !proxy.nil?
    }

    match_processes[:proxy] = proxy
    @table_information[match.id] = match_processes

    self
  end

  def play!(params, match, connection_to_browser)
    unless @table_information[match.id]
      log(__method__, msg: "Ignoring request to play in match #{match.id} that doesn't exist.")
      return self
    end

    proxy = @table_information[match.id][:proxy]

    unless proxy
      log(__method__, msg: "Ignoring request to play in match #{match.id} in seat #{match.seat} when no such proxy exists.")
      return self
    end

    action = PokerAction.new(
      params.retrieve_parameter_or_raise_exception('action'),
      {modifier: params['modifier']}
    )

    log __method__, {
      match_id: match.id,
      num_tables: @table_information.length
    }

    begin
      proxy.play! action do |players_at_the_table|
        connection_to_browser.send({
          reply: ApplicationDefs::PLAY_ACTION_REQUEST_CODE,
          match_id: match.id
        }.to_json)
      end
    rescue => e
      handle_exception match.id, "unable to take action #{action.to_acpc}: #{e.message}"
      raise e
    end

    if proxy.match_ended?
      log __method__, msg: "Deleting background processes with match ID #{match.id}"
      @table_information.delete match.id
    end

    self
  end
end
end