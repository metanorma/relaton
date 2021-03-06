require "yaml"
require_relative "registry"
require_relative "db_cache"

module Relaton
  class RelatonError < StandardError; end

  class Db
    # @param global_cache [String] directory of global DB
    # @param local_cache [String] directory of local DB
    def initialize(global_cache, local_cache)
      @registry = Relaton::Registry.instance
      @db = open_cache_biblio(global_cache, type: :global)
      @local_db = open_cache_biblio(local_cache, type: :local)
      @static_db = open_cache_biblio File.expand_path("../relaton/static_cache", __dir__)
      @queues = {}
    end

    # Move global and/or local caches to anothe dirs
    # @param new_global_dir [String, nil]
    # @param new_local_dir [String, nil]
    def mv(new_global_dir, new_local_dir)
      @db.mv new_global_dir
      @local_db.mv new_local_dir
    end

    # Clear global and local databases
    def clear
      @db.clear
      @local_db.clear
    end

    ##
    # The class of reference requested is determined by the prefix of the code:
    # GB Standard for gbbib, IETF for ietfbib, ISO for isobib, IEC or IEV for iecbib,
    #
    # @param code [String] the ISO standard Code to look up (e.g. "ISO 9000")
    # @param year [String] the year the standard was published (optional)
    #
    # @param opts [Hash] options
    # @option opts [Boolean] :all_parts If all-parts reference is required
    # @option opts [Boolean] :keep_year If undated reference should return actual reference with year
    # @option opts [Integer] :retries (1) Number of network retries
    #
    # @return [nil, RelatonBib::BibliographicItem, RelatonIsoBib::IsoBibliographicItem,
    #   RelatonItu::ItuBibliographicItem, RelatonIetf::IetfBibliographicItem,
    #   RelatonIec::IecBibliographicItem, RelatonIeee::IeeeBibliographicItem,
    #   RelatonNist::NistBibliongraphicItem, RelatonGb::GbbibliographicItem,
    #   RelatonOgc::OgcBibliographicItem, RelatonCalconnect::CcBibliographicItem]
    #   RelatonBipm::BipmBibliographicItem, RelatonIho::IhoBibliographicItem,
    #   RelatonOmg::OmgBibliographicItem RelatinUn::UnBibliographicItem,
    #   RelatonW3c::W3cBibliographicItem
    ##
    def fetch(code, year = nil, opts = {})
      stdclass = standard_class(code) || return
      processor = @registry.processors[stdclass]
      ref = processor.respond_to?(:urn_to_code) ? processor.urn_to_code(code)&.first : code
      ref ||= code
      result = combine_doc ref, year, opts, stdclass
      result ||= check_bibliocache(ref, year, opts, stdclass)
      result
    end

    # @see Relaton::Db#fetch
    def fetch_db(code, year = nil, opts = {})
      opts[:fetch_db] = true
      fetch code, year, opts
    end

    # fetch all standards from DB
    # @param test [String, nil]
    # @param edition [String], nil
    # @param year [Integer, nil]
    # @return [Array]
    def fetch_all(text = nil, edition: nil, year: nil)
      result = @static_db.all { |file, yml| search_yml file, yml, text, edition, year }.compact
      db = @db || @local_db
      result += db.all { |file, xml| search_xml file, xml, text, edition, year }.compact if db
      result
    end

    # Fetch asynchronously
    def fetch_async(code, year = nil, opts = {}, &_block) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      stdclass = standard_class code
      if stdclass
        unless @queues[stdclass]
          processor = @registry.processors[stdclass]
          wp = WorkersPool.new(processor.threads) { |args| yield fetch *args }
          @queues[stdclass] = { queue: Queue.new, workers_pool: wp }
          Thread.new { process_queue @queues[stdclass] }
        end
        @queues[stdclass][:queue] << [code, year, opts]
      else yield nil
      end
    end

    # @param code [String]
    # @param year [String, NilClass]
    # @param stdclass [Symbol, NilClass]
    #
    # @param opts [Hash]
    # @option opts [Boolean] :all_parts If all-parts reference is required
    # @option opts [Boolean] :keep_year If undated reference should return actual reference with year
    # @option opts [Integer] :retries (1) Number of network retries
    #
    # @return [nil, RelatonBib::BibliographicItem, RelatonIsoBib::IsoBibliographicItem,
    #   RelatonItu::ItuBibliographicItem, RelatonIetf::IetfBibliographicItem,
    #   RelatonIec::IecBibliographicItem, RelatonIeee::IeeeBibliographicItem,
    #   RelatonNist::NistBibliongraphicItem, RelatonGb::GbbibliographicItem,
    #   RelatonOgc::OgcBibliographicItem, RelatonCalconnect::CcBibliographicItem]
    #   RelatonBipm::BipmBibliographicItem, RelatonIho::IhoBibliographicItem,
    #   RelatonOmg::OmgBibliographicItem RelatinUn::UnBibliographicItem,
    #   RelatonW3c::W3cBibliographicItem
    def fetch_std(code, year = nil, stdclass = nil, opts = {})
      std = nil
      @registry.processors.each do |name, processor|
        std = name if processor.prefix == stdclass
      end
      std = standard_class(code) or return nil unless std

      check_bibliocache(code, year, opts, std)
    end

    # The document identifier class corresponding to the given code
    # @param code [String]
    # @return [Array]
    def docid_type(code)
      stdclass = standard_class(code) or return [nil, code]
      _prefix, code = strip_id_wrapper(code, stdclass)
      [@registry.processors[stdclass].idtype, code]
    end

    # @param key [String]
    # @return [Hash]
    def load_entry(key)
      unless @local_db.nil?
        entry = @local_db[key]
        return entry if entry
      end
      @db[key]
    end

    # @param key [String]
    # @param value [String] Bibitem xml serialisation.
    # @option value [String] Bibitem xml serialisation.
    def save_entry(key, value)
      @db.nil? || (@db[key] = value)
      @local_db.nil? || (@local_db[key] = value)
    end

    # list all entries as a serialization
    # @return [String]
    def to_xml
      db = @local_db || @db || return
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.documents do
          xml.parent.add_child db.all.join(" ")
        end
      end.to_xml
    end

    private

    # @param file [String] file path
    # @param yml [String] content in YAML format
    # @param text [String, nil] text to serach
    # @param edition [String, nil] edition to filter
    # @param year [Integer, nil] year to filter
    # @return [BibliographicItem, nil]
    def search_yml(file, yml, text, edition, year)
      item = search_edition_year(file, yml, edition, year)
      return unless item

      item if match_xml_text(item.to_xml(bibdata: true), text)
    end

    # @param file [String] file path
    # @param xml [String] content in XML format
    # @param text [String, nil] text to serach
    # @param edition [String, nil] edition to filter
    # @param year [Integer, nil] year to filter
    # @return [BibliographicItem, nil]
    def search_xml(file, xml, text, edition, year)
      return unless text.nil? || match_xml_text(xml, text)

      search_edition_year(file, xml, edition, year)
    end

    # @param file [String] file path
    # @param content [String] content in XML or YAmL format
    # @param edition [String, nil] edition to filter
    # @param year [Integer, nil] year to filter
    # @return [BibliographicItem, nil]
    def search_edition_year(file, content, edition, year) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      processor = @registry.processors[standard_class(file.split("/")[-2])]
      item = file.match?(/xml$/) ? processor.from_xml(content) : processor.hash_to_bib(YAML.safe_load(content))
      item if (edition.nil? || item.edition == edition) &&
        (year.nil? || item.date.detect { |d| d.type == "published" && d.on(:year) == year })
    end

    # @param xml [String] content in XML format
    # @param text [String, nil] text to serach
    # @return [Boolean]
    def match_xml_text(xml, text)
      %r{((?<attr>=((?<apstr>')|"))|>).*?#{text}.*?(?(<attr>)(?(<apstr>)'|")|<)}mi.match?(xml)
    end

    # @param code [String]
    # @param year [String, nil]
    # @param stdslass [String]
    #
    # @param opts [Hash] options
    # @option opts [Boolean] :all_parts If all-parts reference is required
    # @option opts [Boolean] :keep_year If undated reference should return actual reference with year
    # @option opts [Integer] :retries (1) Number of network retries
    #
    # @return [nil, RelatonBib::BibliographicItem, RelatonIsoBib::IsoBibliographicItem,
    #   RelatonItu::ItuBibliographicItem, RelatonIetf::IetfBibliographicItem,
    #   RelatonIec::IecBibliographicItem, RelatonIeee::IeeeBibliographicItem,
    #   RelatonNist::NistBibliongraphicItem, RelatonGb::GbbibliographicItem,
    #   RelatonOgc::OgcBibliographicItem, RelatonCalconnect::CcBibliographicItem]
    #   RelatonBipm::BipmBibliographicItem, RelatonIho::IhoBibliographicItem,
    #   RelatonOmg::OmgBibliographicItem RelatinUn::UnBibliographicItem,
    #   RelatonW3c::W3cBibliographicItem
    def combine_doc(code, year, opts, stdclass) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      if (refs = code.split " + ").size > 1
        reltype = "derivedFrom"
        reldesc = nil
      elsif (refs = code.split ", ").size > 1
        reltype = "complements"
        reldesc = RelatonBib::FormattedString.new content: "amendment"
      else return
      end

      doc = @registry.processors[stdclass].hash_to_bib docid: { id: code }
      ref = refs[0]
      updates = check_bibliocache(ref, year, opts, stdclass)
      doc.relation << RelatonBib::DocumentRelation.new(bibitem: updates, type: "updates") if updates
      refs[1..-1].each_with_object(doc) do |c, d|
        bib = check_bibliocache("#{ref}/#{c}", year, opts, stdclass)
        if bib
          d.relation << RelatonBib::DocumentRelation.new(type: reltype, description: reldesc, bibitem: bib)
        end
      end
    end

    # @param code [String] code of standard
    # @return [Symbol] standard class name
    def standard_class(code)
      @registry.processors.each do |name, processor|
        return name if /^(urn:)?#{processor.prefix}/i.match?(code) ||
          processor.defaultprefix.match(code)
      end
      allowed = @registry.processors.reduce([]) do |m, (_k, v)|
        m << v.prefix
      end
      warn <<~WARN
        #{code} does not have a recognised prefix: #{allowed.join(', ')}.
        See https://github.com/relaton/relaton/ for instructions on prefixing and wrapping document identifiers to disambiguate them.
      WARN
    end

    # TODO: i18n
    # Fofmat ID
    # @param code [String]
    # @param year [String]
    #
    # @param opts [Hash]
    # @option opts [Boolean] :all_parts If all-parts reference is required
    # @option opts [Boolean] :keep_year If undated reference should return actual reference with year
    # @option opts [Integer] :retries (1) Number of network retries
    #
    # @param stdClass [Symbol]
    # @return [Array<String>] docid and code
    def std_id(code, year, opts, stdclass)
      prefix, code = strip_id_wrapper(code, stdclass)
      ret = code
      ret += (stdclass == :relaton_gb ? "-" : ":") + year if year
      ret += " (all parts)" if opts[:all_parts]
      ["#{prefix}(#{ret.strip})", code]
    end

    # Find prefix and clean code
    # @param code [String]
    # @param stdClass [Symbol]
    # @return [Array]
    def strip_id_wrapper(code, stdclass)
      prefix = @registry.processors[stdclass].prefix
      code = code.sub(/\u2013/, "-").sub(/^#{prefix}\((.+)\)$/, "\\1")
      [prefix, code]
    end

    # @param entry [String] XML string
    # @param stdclass [Symbol]
    # @return [nil, RelatonBib::BibliographicItem, RelatonIsoBib::IsoBibliographicItem,
    #   RelatonItu::ItuBibliographicItem, RelatonIetf::IetfBibliographicItem,
    #   RelatonIec::IecBibliographicItem, RelatonIeee::IeeeBibliographicItem,
    #   RelatonNist::NistBibliongraphicItem, RelatonGb::GbbibliographicItem,
    #   RelatonOgc::OgcBibliographicItem, RelatonCalconnect::CcBibliographicItem]
    #   RelatonBipm::BipmBibliographicItem, RelatonIho::IhoBibliographicItem,
    #   RelatonOmg::OmgBibliographicItem RelatinUn::UnBibliographicItem,
    #   RelatonW3c::W3cBibliographicItem
    def bib_retval(entry, stdclass)
      entry.nil? || entry.match?(/^not_found/) ? nil : @registry.processors[stdclass].from_xml(entry)
    end

    # @param code [String]
    # @param year [String]
    #
    # @param opts [Hash]
    # @option opts [Boolean] :all_parts If all-parts reference is required
    # @option opts [Boolean] :keep_year If undated reference should return actual reference with year
    # @option opts [Integer] :retries (1) Number of network retries
    #
    # @param stdclass [Symbol]
    # @return [nil, RelatonBib::BibliographicItem, RelatonIsoBib::IsoBibliographicItem,
    #   RelatonItu::ItuBibliographicItem, RelatonIetf::IetfBibliographicItem,
    #   RelatonIec::IecBibliographicItem, RelatonIeee::IeeeBibliographicItem,
    #   RelatonNist::NistBibliongraphicItem, RelatonGb::GbbibliographicItem,
    #   RelatonOgc::OgcBibliographicItem, RelatonCalconnect::CcBibliographicItem]
    #   RelatonBipm::BipmBibliographicItem, RelatonIho::IhoBibliographicItem,
    #   RelatonOmg::OmgBibliographicItem RelatinUn::UnBibliographicItem,
    #   RelatonW3c::W3cBibliographicItem
    def check_bibliocache(code, year, opts, stdclass) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
      id, searchcode = std_id(code, year, opts, stdclass)
      yaml = @static_db[id]
      return @registry.processors[stdclass].hash_to_bib YAML.safe_load(yaml) if yaml

      db = @local_db || @db
      altdb = @local_db && @db ? @db : nil
      if db.nil?
        return if opts[:fetch_db]

        bibentry = new_bib_entry(searchcode, year, opts, stdclass, db: db, id: id)
        return bib_retval(bibentry, stdclass)
      end

      db.delete(id) unless db.valid_entry?(id, year)
      if altdb
        return bib_retval(altdb[id], stdclass) if opts[:fetch_db]

        db.clone_entry id, altdb if altdb.valid_entry? id, year
        db[id] ||= new_bib_entry(searchcode, year, opts, stdclass, db: db, id: id)
        altdb.clone_entry(id, db) if !altdb.valid_entry?(id, year)
      else
        return bib_retval(db[id], stdclass) if opts[:fetch_db]

        db[id] ||= new_bib_entry(searchcode, year, opts, stdclass, db: db, id: id)
      end
      bib_retval(db[id], stdclass)
    end

    # @param code [String]
    # @param year [String]
    #
    # @param opts [Hash]
    # @option opts [Boolean] :all_parts If all-parts reference is required
    # @option opts [Boolean] :keep_year If undated reference should return actual reference with year
    # @option opts [Integer] :retries (1) Number of network retries
    #
    # @param stdclass [Symbol]
    # @param db [Relaton::DbCache,`NilClass]
    # @param id [String] docid
    # @return [String]
    def new_bib_entry(code, year, opts, stdclass, **args) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      bib = net_retry(code, year, opts, stdclass, opts.fetch(:retries, 1))
      bib_id = bib&.docidentifier&.first&.id

      # when docid doesn't match bib's id then return a reference to bib's id
      if args[:db] && args[:id] && bib_id && args[:id] !~ %r{#{Regexp.quote("(#{bib_id})")}}
        bid = std_id(bib.docidentifier.first.id, nil, {}, stdclass).first
        args[:db][bid] ||= bib_entry bib
        "redirection #{bid}"
      else bib_entry bib
      end
    end

    # @raise [RelatonBib::RequestError]
    def net_retry(code, year, opts, stdclass, retries)
      @registry.processors[stdclass].get(code, year, opts)
    rescue RelatonBib::RequestError => e
      raise e unless retries > 1

      net_retry(code, year, opts, stdclass, retries - 1)
    end

    # @param bib [RelatonGb::GbBibliongraphicItem, RelatonIsoBib::IsoBibliographicItem,
    #   RelatonIetf::IetfBibliographicItem, RelatonItu::ItuBibliographicItem,
    #   RelatonNist::NistBibliongraphicItem, RelatonOgc::OgcBibliographicItem]
    # @return [String] XML or "not_found mm-dd-yyyy"
    def bib_entry(bib)
      if bib.respond_to? :to_xml
        bib.to_xml(bibdata: true)
      else
        "not_found #{Date.today}"
      end
    end

    # @param dir [String, nil] DB directory
    # @param type [Symbol]
    # @return [Relaton::DbCache, NilClass]
    def open_cache_biblio(dir, type: :static)
      return nil if dir.nil?

      db = DbCache.new dir, type == :static ? "yml" : "xml"
      return db if type == :static

      Dir["#{dir}/*/"].each do |fdir|
        next if db.check_version?(fdir)

        FileUtils.rm_rf(Dir.glob(fdir + "/*"), secure: true)
        db.set_version fdir
        warn "[relaton] cache #{fdir}: version is obsolete and cache is cleared."
      end
      db
    end

    # @param qwp [Hash]
    # @option qwp [Queue] :queue The queue of references to fetch
    # @option qwp [Relaton::WorkersPool] :workers_pool The pool of workers
    def process_queue(qwp)
      while args = qwp[:queue].pop
        qwp[:workers_pool] << args
      end
    end
  end
end
