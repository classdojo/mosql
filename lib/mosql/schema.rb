module MoSQL
  class SchemaError < StandardError; end;

  class Schema
    include MoSQL::Logging

    def to_ordered_hash(lst)
      hash = BSON::OrderedHash.new
      lst.each do |ent|
        raise "Invalid ordered hash entry #{ent.inspect}" unless ent.is_a?(Hash) && ent.keys.length == 1
        field, type = ent.first
        hash[field] = type
      end
      hash
    end

    def parse_spec(spec)
      out = spec.dup
      out[:columns] = to_ordered_hash(spec[:columns])
      out
    end

    def initialize(map)
      @map = {}
      map.each do |dbname, db|
        @map[dbname] ||= {}
        db.each do |cname, spec|
          @map[dbname][cname] = parse_spec(spec)
        end
      end
    end

    def create_schema(db, clobber=false)
      @map.values.map(&:values).flatten.each do |collection|
        meta = collection[:meta]
        log.info("Creating table '#{meta[:table]}'...")
        db.send(clobber ? :create_table! : :create_table?, meta[:table]) do
          collection[:columns].each do |field, type|
            column field, type
          end
          if meta[:extra_props]
            column '_extra_props', 'TEXT'
          end
          primary_key [:_id]
        end
      end
    end

    def find_ns(ns)
      db, collection = ns.split(".")
      schema = (@map[db] || {})[collection]
      if schema.nil?
        log.debug("No mapping for ns: #{ns}")
        return nil
      end
      schema
    end

    def find_ns!(ns)
      schema = find_ns(ns)
      raise SchemaError.new("No mapping for namespace: #{ns}") if schema.nil?
      schema
    end

    def transform(ns, obj, schema=nil)
      schema ||= find_ns!(ns)

      obj = obj.dup
      row = []
      schema[:columns].each do |name, type|

        if name.include? "."
          v = resolve_dot_syntax(obj, name)
        else
          v = obj.delete(name)
        end

        # log.info("column #{name}=#{v}")

        case v
        when BSON::Binary, BSON::ObjectId
          v = v.to_s
        end
        row << v
      end

      if schema[:meta][:extra_props]
        # Kludgily delete binary blobs from _extra_props -- they may
        # contain invalid UTF-8, which to_json will not properly encode.
        obj.each do |k,v|
          obj.delete(k) if v.is_a?(BSON::Binary)
        end
        row << obj.to_json
      end

      log.debug { "Transformed: #{row.inspect}" }

      row
    end

    def resolve_dot_syntax(obj, selector)
      parts = selector.is_a?(Array) ? selector : selector.split(".")

      if !obj.is_a?(BSON::OrderedHash)
        return nil
      end

      child_obj = obj[parts.shift]

      if parts.length == 0
        return child_obj
      end

        resolve_dot_syntax(child_obj, parts)
    end

    def all_columns(schema)
      cols = schema[:columns].keys
      if schema[:meta][:extra_props]
        cols << "_extra_props"
      end
      cols
    end

    def copy_data(db, ns, objs)
      schema = find_ns!(ns)
      data = objs.map { |o| transform_to_copy(ns, o, schema) }.join("\n")
      db.synchronize do |pg|
        sql = "COPY \"#{schema[:meta][:table]}\" " +
          "(#{all_columns(schema).map {|c| "\"#{c}\""}.join(",")}) FROM STDIN"
        pg.execute(sql)
        objs.each do |o|
          pg.put_copy_data(transform_to_copy(ns, o, schema) + "\n")
        end
        pg.put_copy_end
        begin
          pg.get_result.check
        rescue PGError => e
          db.send(:raise_error, e)
        end
      end
    end

    def quote_copy(val)
      case val
      when nil
        "\\N"
      when true
        't'
      when false
        'f'
      else
        v = val.to_s
        v.force_encoding("binary")
        v = v.encode("utf-8", :invalid => :replace, :undef => :replace)
        val.to_s.gsub(/([\\\t\n\r])/, '\\\\\\1')
      end
    end

    def transform_to_copy(ns, row, schema=nil)
      row.map { |c| quote_copy(c) }.join("\t")
    end

    def table_for_ns(ns)
      find_ns!(ns)[:meta][:table]
    end

    def all_mongo_dbs
      @map.keys
    end

    def collections_for_mongo_db(db)
      (@map[db]||{}).keys
    end
  end
end
