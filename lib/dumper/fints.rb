class Dumper
  # Implements logic to fetch transactions via the Fints protocol
  # and implements methods that convert the response to meaningful data.
  class Fints < Dumper
    require 'ruby_fints'

    def initialize(params = {})
      @ynab_id  = params.fetch('ynab_id')
      @username = params.fetch('username').to_s
      @password = params.fetch('password').to_s
      @iban     = params.fetch('iban')
      @endpoint = params.fetch('fints_endpoint')
      @blz      = params.fetch('fints_blz')
    end

    def fetch_transactions
      FinTS::Client.logger.level = Logger::WARN
      client = FinTS::PinTanClient.new(@blz, @username, @password, @endpoint)

      account = client.get_sepa_accounts.find { |a| a[:iban] == @iban }
      statement = client.get_statement(account, Date.today - 35, Date.today)

      statement.map { |t| to_ynab_transaction(t) }
    end

    private

    def account_id
      @ynab_id
    end

    def date(transaction)
      transaction.entry_date || transaction.date
    rescue NoMethodError
      # https://github.com/schurig/ynab-bank-importer/issues/52
      # Some banks think Feb 29 and 30 exist in non-leap years.
      entry_date(transaction) || to_date(transaction['date'])
    end

    def payee_name(transaction)
      transaction.name.try(:strip)
    end

    def payee_iban(transaction)
      transaction.iban
    end

    def memo(transaction)
      [
        transaction.description,
        transaction.information
      ].compact.join(' / ').try(:strip)
    end

    def amount(transaction)
      (transaction.amount * transaction.sign * 1000).to_i
    end

    def withdrawal?(transaction)
      memo = memo(transaction)
      return nil unless memo

      memo.include?('Atm') || memo.include?('Bargeld')
    end

    def import_id(transaction)
      Digest::SHA2.hexdigest("#{transaction.date.to_time.to_i}#{transaction.amount}#{transaction.name}").slice(0, 36)
    end

    # Patches

    # taken from https://github.com/railslove/cmxl/blob/master/lib/cmxl/field.rb
    # and modified so that it takes the last day of the month if the provided day
    # doesn't exist in that month.
    # See issue: https://github.com/schurig/ynab-bank-importer/issues/52
    DATE = /(?<year>\d{0,2})(?<month>\d{2})(?<day>\d{2})/
    def to_date(date, year = nil)
      if match = date.to_s.match(DATE)
        year ||= "20#{match['year'] || Date.today.strftime('%y')}"
        month = match['month']
        day = match['day']

        begin
          Date.new(year.to_i, month.to_i, day.to_i)
        rescue ArgumentError
          # Take the last day of that month
          Date.civil(year.to_i, month.to_i, -1)
        end
      else
        date
      end
    end

    def entry_date(transaction)
      data = transaction.data
      date = to_date(data['date'])

      return unless transaction.data['entry_date'] && date

      entry_date_with_date_year = to_date(data['entry_date'], date.year)
      if date.month == 1 && date.month < entry_date_with_date_year.month
        to_date(data['entry_date'], date.year - 1)
      else
        to_date(data['entry_date'], date.year)
      end
    end
  end
end
