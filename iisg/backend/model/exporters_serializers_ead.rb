# encoding: utf-8
require 'nokogiri'
require 'securerandom'
require 'cgi'

class EADSerializer < ASpaceExport::Serializer
  serializer_for :ead

  # Allow plugins to hook in to record processing by providing their own
  # serialization step (a class with a 'call' method accepting the arguments
  # defined in `run_serialize_step`.
  def self.add_serialize_step(serialize_step)
    @extra_serialize_steps ||= []
    @extra_serialize_steps << serialize_step
  end

  def self.run_serialize_step(data, xml, fragments, context)
    Array(@extra_serialize_steps).each do |step|
      step.new.call(data, xml, fragments, context)
    end
  end


  def prefix_id(id)
    if id.nil? or id.empty? or id == 'null'
      ""
    elsif id =~ /^#{@id_prefix}/
      id
    else
      "#{@id_prefix}#{id}"
    end
  end

  def xml_errors(content)
    # there are message we want to ignore. annoying that java xml lib doesn't
    # use codes like libxml does...
    ignore = [ /Namespace prefix .* is not defined/, /The prefix .* is not bound/  ]
    ignore = Regexp.union(ignore)
    # the "wrap" is just to ensure that there is a psuedo root element to eliminate a "false" error
    Nokogiri::XML("<wrap>#{content}</wrap>").errors.reject { |e| e.message =~ ignore  }
  end

  # ANW-716: We may have content with a mix of loose '&' chars that need to be escaped, along with pre-escaped HTML entities
  # Example:
  # c                 => "This is the &lt; test & for the <title>Sanford &amp; Son</title>
  # escape_content(c) => "This is the &lt; test &amp; for the <title>Sanford &amp; Son</title>
  # we want to leave the pre-escaped entities alone, and escape the loose & chars

  def escape_content(content)
    # first, find any pre-escaped entities and "mark" them by replacing & with @@
    # so something like &lt; becomes @@lt;
    # and &#1234 becomes @@#1234

    content.gsub!(/&\w+;/) {|t| t.gsub('&', '@@')}
    content.gsub!(/&#\d{4}/) {|t| t.gsub('&', '@@')}
    content.gsub!(/&#\d{3}/) {|t| t.gsub('&', '@@')}

    # now we know that all & characters remaining are not part of some pre-escaped entity, and we can escape them safely
    content.gsub!('&', '&amp;')

    # 'unmark' our pre-escaped entities
    content.gsub!(/@@\w+;/) {|t| t.gsub('@@', '&')}
    content.gsub!(/@@#\d{4}/) {|t| t.gsub('@@', '&')}
    content.gsub!(/@@#\d{3}/) {|t| t.gsub('@@', '&')}

    return content
  end


  def handle_linebreaks(content)
    # 4archon...
    content.gsub!("\n\t", "\n\n")
    # if there's already p tags, just leave as is
    return content if ( content.strip =~ /^<p(\s|\/|>)/ or content.strip.length < 1 )
    original_content = content
    blocks = content.split("\n\n").select { |b| !b.strip.empty? }
    if blocks.length > 1
      content = blocks.inject("") do |c,n|
        c << "<p>#{escape_content(n.chomp)}</p>"
      end
    else
      content = "<p>#{escape_content(content.strip)}</p>"
    end

    # just return the original content if there's still problems
    xml_errors(content).any? ? original_content : content
  end

  def strip_p(content)
    content.gsub("<p>", "").gsub("</p>", "").gsub("<p/>", '')
  end

  def remove_smart_quotes(content)
    content = content.gsub(/\xE2\x80\x9C/, '"').gsub(/\xE2\x80\x9D/, '"').gsub(/\xE2\x80\x98/, "\'").gsub(/\xE2\x80\x99/, "\'")
  end


  # ANW-669: Fix for attributes in mixed content causing errors when validating against the EAD schema.

  # If content looks like it contains a valid XML element with an attribute from the expected list,
  # then replace the attribute like " foo=" with " xlink:foo=".

  # References used for valid element and attribute names:
  # https://www.xml.com/pub/a/2001/07/25/namingparts.html
  # https://razzed.com/2009/01/30/valid-characters-in-attribute-names-in-htmlxml/

  def add_xlink_prefix(content)
    %w{ actuate arcrole entityref from href id linktype parent role show target title to xpointer }.each do | xa |
      content.gsub!(/ #{xa}=/) {|match| " xlink:#{match.strip}"} if content =~ / #{xa}=/
    end
    content
  end

  def sanitize_mixed_content(content, context, fragments, allow_p = false  )
    # remove smart quotes from text
    content = remove_smart_quotes(content)

    # br's should be self closing
    content = content.gsub("<br>", "<br/>").gsub("</br>", '')
    # lets break the text, if it has linebreaks but no p tags.

    if allow_p
      content = handle_linebreaks(content)
    else
      escape_content(content)
      content = strip_p(content)
    end

    # ANW-669 - only certain EAD elements will have attributes that need
    # xlink added so only do this processing if the element is there
    # attribute check is inside the add_xlink_prefix method
    xlink_eles = %w{ arc archref bibref extptr extptrloc extref extrefloc linkgrp ptr ptrloc ref refloc resource title }
    content = add_xlink_prefix(content) if xlink_eles.any? { |word| content =~ /<#{word}\s/ }

    begin
      if ASpaceExport::Utils.has_html?(content)
        context.text (fragments << content )
      else
        context.text content.gsub("&amp;", "&") #thanks, Nokogiri
      end
    rescue
      context.cdata content
    end
  end

  def stream(data)
    @stream_handler = ASpaceExport::StreamHandler.new
    @fragments = ASpaceExport::RawXMLHandler.new
    @include_unpublished = data.include_unpublished?
    @include_daos = data.include_daos?
    @use_numbered_c_tags = data.use_numbered_c_tags?
    @id_prefix = I18n.t('archival_object.ref_id_export_prefix', :default => 'aspace_')

    doc = Nokogiri::XML::Builder.new(:encoding => "UTF-8") do |xml|
      begin

      ead_attributes = {
        'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance',
        'xsi:schemaLocation' => 'urn:isbn:1-931666-22-9 http://www.loc.gov/ead/ead.xsd',
        'xmlns:xlink' => 'http://www.w3.org/1999/xlink'
      }

      if data.publish === false
        ead_attributes['audience'] = 'internal'
      end

      xml.ead( ead_attributes ) {

        xml.text (
          @stream_handler.buffer { |xml, new_fragments|
            serialize_eadheader(data, xml, new_fragments)
          })

        atts = {:level => data.level, :otherlevel => data.other_level, :type => 'inventory', :relatedencoding => 'MARC21'}
        atts.reject! {|k, v| v.nil?}

        xml.archdesc(atts) {

          xml.did {

            if (val = data.title)
							#xml.unittitle  {   sanitize_mixed_content(val, xml, @fragments) }
							xml.unittitle({:label=>'Title', :encodinganalog=>'245$a'})  {   sanitize_mixed_content(val, xml, @fragments) }
            end

            serialize_dates(data, xml, @fragments)

						# added
						attributes = {:countrycode => data.repo.country,
										:label => 'Collection no.',
										:encodinganalog => '852$j',
										:repositorycode => data.mainagencycode}.reject{|k,v| v.nil? || v.empty? || v == "null" }

						# modified
						#xml.unitid (0..3).map{|i| data.send("id_#{i}")}.compact.join('.') # ORIGINAL
						xml.unitid (attributes) { sanitize_mixed_content((0..3).map{|i| data.send("id_#{i}")}.compact.join('.'), xml, @fragments) }

            if @include_unpublished
              data.external_ids.each do |exid|
                xml.unitid ({ "audience" => "internal", "type" => exid['source'], "identifier" => exid['external_id']}) { xml.text exid['external_id']}
							end
            end

            serialize_origination(data, xml, @fragments)

            serialize_extents(data, xml, @fragments)

            if (val = data.language)
							# modified
							#xml.langmaterial {
							xml.langmaterial({:label => 'Language of Material', :encodinganalog => '546$a'}) {

								# modified
								#xml.language(:langcode => val) {
								xml.language({:langcode => val, :encodinganalog => '041$a'}) {
									# added
                	taal = I18n.t("enumerations.language_iso639_2.#{val}", :default => val)
									taal = taal.sub('Dutch; Flemish', 'Dutch')

									# modified
									#xml.text I18n.t("enumerations.language_iso639_2.#{val}", :default => val)
									xml.text taal
                }
              }
            end

            if (val = data.repo.name)
            	# modified
							#xml.repository {
							xml.repository ({:label=>'Repository',:encodinganalog=>'852$a'}) {
                xml.corpname { sanitize_mixed_content(val, xml, @fragments) }

								#added
								xml.address {
									xml.addressline {
										xml.text 'Cruquiusweg 31'
									}
									xml.addressline {
										xml.text '1019 AT  Amsterdam'
									}
									xml.addressline {
										xml.text 'Nederland'
									}
									xml.addressline {
										xml.text 'ask@iisg.nl'
									}
									xml.addressline {
										sanitize_mixed_content('URL: <extptr xlink:href="https://iisg.amsterdam/en" xlink:show="new" xlink:title="https://iisg.amsterdam/en" xlink:type="simple"/>', xml, @fragments)
									}
								}
              }
            end

            serialize_did_notes(data, xml, @fragments)

            if (languages = data.lang_materials)
              serialize_languages(languages, xml, @fragments)
            end

            data.instances_with_sub_containers.each do |instance|
              serialize_container(instance, xml, @fragments)
            end

            EADSerializer.run_serialize_step(data, xml, @fragments, :did)

          }# </did>

          data.digital_objects.each do |dob|
            serialize_digital_object(dob, xml, @fragments)
          end

          serialize_nondid_notes(data, xml, @fragments)

          serialize_bibliographies(data, xml, @fragments)

          serialize_indexes(data, xml, @fragments)

          serialize_controlaccess(data, xml, @fragments)

          EADSerializer.run_serialize_step(data, xml, @fragments, :archdesc)

            # modified
            #xml.dsc {
            xml.dsc ({:type => 'combined'}) {

            data.children_indexes.each do |i|
              xml.text(
                       @stream_handler.buffer {|xml, new_fragments|
                         serialize_child(data.get_child(i), xml, new_fragments)
                       }
                       )
            end
          }
        }
      }

    rescue => e
      xml.text  "ASPACE EXPORT ERROR : YOU HAVE A PROBLEM WITH YOUR EXPORT OF YOUR RESOURCE. THE FOLLOWING INFORMATION MAY HELP:\n
                MESSAGE: #{e.message.inspect}  \n
                TRACE: #{e.backtrace.inspect} \n "
    end



    end
    doc.doc.root.add_namespace nil, 'urn:isbn:1-931666-22-9'

    Enumerator.new do |y|
      @stream_handler.stream_out(doc, @fragments, y)
    end


  end

  # this extracts <head> content and returns it. optionally, you can provide a
  # backup text node that will be returned if there is no <head> nodes in the
  # content
  def extract_head_text(content, backup = "")
    content ||= ""
    match = content.strip.match(/<head( [^<>]+)?>(.+?)<\/head>/)
    if match.nil? # content has no head so we return it as it
      return [content, backup ]
    else
      [ content.gsub(match.to_a.first, ''), match.to_a.last]
    end
  end

  def serialize_child(data, xml, fragments, c_depth = 1)
    begin
    return if data["publish"] === false && !@include_unpublished
    return if data["suppressed"] === true

    tag_name = @use_numbered_c_tags ? :"c#{c_depth.to_s.rjust(2, '0')}" : :c

    atts = {:level => data.level, :otherlevel => data.other_level, :id => prefix_id(data.ref_id)}

    if data.publish === false
      atts[:audience] = 'internal'
    end

    atts.reject! {|k, v| v.nil?}
    xml.send(tag_name, atts) {

      xml.did {
        if (val = data.title)
          xml.unittitle {  sanitize_mixed_content( val,xml, fragments) }
        end

        if AppConfig[:arks_enabled]
          ark_url = ArkName::get_ark_url(data.id, :archival_object)
          if ark_url
            # <unitid><extref xlink:href="ARK" xlink:actuate="onLoad" xlink:show="new" xlink:linktype="simple">ARK</extref></unitid>
            xml.unitid {
              xml.extref ({"xlink:href" => ark_url,
                          "xlink:actuate" => "onLoad",
                          "xlink:show" => "new",
                          "xlink:type" => "simple"
                          }) { xml.text 'Archival Resource Key' }
                          }
          end
        end

        if !data.component_id.nil? && !data.component_id.empty?
          xml.unitid data.component_id
        end

        if @include_unpublished
          data.external_ids.each do |exid|
            xml.unitid  ({ "audience" => "internal",  "type" => exid['source'], "identifier" => exid['external_id']}) { xml.text exid['external_id']}
          end
        end

        serialize_origination(data, xml, fragments)
        serialize_extents(data, xml, fragments)
        serialize_dates(data, xml, fragments)
        serialize_did_notes(data, xml, fragments)

        EADSerializer.run_serialize_step(data, xml, fragments, :did)

        data.instances_with_sub_containers.each do |instance|
          serialize_container(instance, xml, @fragments)
        end

        if @include_daos
          data.instances_with_digital_objects.each do |instance|
            serialize_digital_object(instance['digital_object']['_resolved'], xml, fragments)
          end
        end
      }

      serialize_nondid_notes(data, xml, fragments)

      serialize_bibliographies(data, xml, fragments)

      serialize_indexes(data, xml, fragments)

      serialize_controlaccess(data, xml, fragments)

      EADSerializer.run_serialize_step(data, xml, fragments, :archdesc)

      data.children_indexes.each do |i|
        xml.text(
                 @stream_handler.buffer {|xml, new_fragments|
                   serialize_child(data.get_child(i), xml, new_fragments, c_depth + 1)
                 }
                 )
      end
    }
    rescue => e
      xml.text "ASPACE EXPORT ERROR : YOU HAVE A PROBLEM WITH YOUR EXPORT OF ARCHIVAL OBJECTS. THE FOLLOWING INFORMATION MAY HELP:\n

                MESSAGE: #{e.message.inspect}  \n
                TRACE: #{e.backtrace.inspect} \n "
    end
  end


  def serialize_origination(data, xml, fragments)
    unless data.creators_and_sources.nil?

			# added
			firstpersname = 1
			firstcorpname = 1

      data.creators_and_sources.each do |link|
        agent = link['_resolved']
        published = agent['publish'] === true

        next if !published && !@include_unpublished

        link['role'] == 'creator' ? role = link['role'].capitalize : role = link['role']
        relator = link['relator']
        sort_name = agent['display_name']['sort_name']
        rules = agent['display_name']['rules']
        source = agent['display_name']['source']
        authfilenumber = agent['display_name']['authority_id']
        node_name = case agent['agent_type']
                    when 'agent_person'; 'persname'
                    when 'agent_family'; 'famname'
                    when 'agent_corporate_entity'; 'corpname'
                    when 'agent_software'; 'name'
                    end

        origination_attrs = {:label => role}
        origination_attrs[:audience] = 'internal' unless published
        xml.origination(origination_attrs) {

				# added
				if node_name == 'persname'
					if firstpersname == 1
						encodinganalog = '100$a'
					else
						encodinganalog = '700$a'
					end
					firstpersname = 0
				elsif node_name == 'corpname'
					if firstcorpname == 1
						encodinganalog = '110$a'
					else
						encodinganalog = '710$a'
					end
					firstcorpname = 0
				else
					encodinganalog = ''
				end

				  # modified
				  #atts = {:role => relator, :source => source, :rules => rules, :authfilenumber => authfilenumber}
				  atts = {:role => relator, :source => source, :rules => rules, :authfilenumber => authfilenumber, :encodinganalog => encodinganalog}
          atts.reject! {|k, v| v.nil?}

          xml.send(node_name, atts) {
            sanitize_mixed_content(sort_name, xml, fragments )
          }
        }
      end
    end
  end

  def serialize_controlaccess(data, xml, fragments)
    if (data.controlaccess_subjects.length + data.controlaccess_linked_agents.length) > 0
			# find all types
			arr_items = []
			data.controlaccess_subjects.each do |item|
				arr_items.push(item[:node_name])
			end
			arr_items = arr_items.uniq

			# loop each type
			arr_items.each do |item|

				xml.controlaccess {

					xml.head {
						txthead = case item
											when 'geogname'
											  'Geographic Names'
											when 'subject'
												'Themes'
											when 'genreform'
												'Material Type'
											else
												''
											end

						xml.text txthead
					}

					#
					firstgeogname = 1

					data.controlaccess_subjects.each do |node_data|

						if item == node_data[:node_name]

						# added
						if node_data[:node_name] == 'geogname'
							if firstgeogname == 1
								node_data[:atts][:encodinganalog] = '044$c'
								node_data[:atts][:role] = 'country of origin'
								node_data[:atts][:normal] = 'NL' # TODO moet dit berekend worden
							else
								node_data[:atts][:encodinganalog] = '651$a'
								node_data[:atts][:role] = 'subject'
								node_data[:atts][:normal] = 'AT' # TODO moet dit berekend worden
							end
							firstgeogname = 0
						elsif node_data[:node_name] == 'subject'
							node_data[:atts][:encodinganalog] = '650$a'
						elsif node_data[:node_name] == 'genreform'
							node_data[:atts][:encodinganalog] = '655$a'
						else
							node_data[:atts][:unknownnodename] = node_data[:node_name]
						end

						xml.send(node_data[:node_name], node_data[:atts]) {
							sanitize_mixed_content( node_data[:content], xml, fragments, ASpaceExport::Utils.include_p?(node_data[:node_name]) )
						}
						end
					end

				} #</controlaccess>

			end


			# find all types
			arr_items = []
			data.controlaccess_linked_agents.each do |item|
				arr_items.push(item[:node_name])
			end
			arr_items = arr_items.uniq

			# loop each type
			arr_items.each do |item|

				xml.controlaccess {

					xml.head {
						txthead = case item
											when 'persname'
												'Persons'
											when 'corpname'
												'Organizations'
											else
												''
											end

						xml.text txthead
					}

					data.controlaccess_linked_agents.each do |node_data|

						if item == node_data[:node_name]

							if node_data[:node_name] == 'persname'
								node_data[:atts][:encodinganalog] = '600$a'
								node_data[:atts][:role] = 'subject'
							elsif node_data[:node_name] == 'corpname'
								node_data[:atts][:encodinganalog] = '610$a'
								node_data[:atts][:role] = 'subject'
							end

							xml.send(node_data[:node_name], node_data[:atts]) {
								sanitize_mixed_content( node_data[:content], xml, fragments,ASpaceExport::Utils.include_p?(node_data[:node_name]) )
							}
						end
					end
				} #</controlaccess>
			end
		end
  end

  def serialize_subnotes(subnotes, xml, fragments, include_p = true)
    subnotes.each do |sn|
      next if sn["publish"] === false && !@include_unpublished

      audatt = sn["publish"] === false ? {:audience => 'internal'} : {}

      title = sn['title']

      case sn['jsonmodel_type']
      when 'note_text'
        sanitize_mixed_content(sn['content'], xml, fragments, include_p )
      when 'note_chronology'
        xml.chronlist(audatt) {
          xml.head { sanitize_mixed_content(title, xml, fragments) } if title

          sn['items'].each do |item|
            xml.chronitem {
              if (val = item['event_date'])
                xml.date { sanitize_mixed_content( val, xml, fragments) }
              end
              if item['events'] && !item['events'].empty?
                xml.eventgrp {
                  item['events'].each do |event|
                    xml.event { sanitize_mixed_content(event, xml, fragments) }
                  end
                }
              end
            }
          end
        }
      when 'note_orderedlist'
        atts = {:type => 'ordered', :numeration => sn['enumeration']}.reject{|k,v| v.nil? || v.empty? || v == "null" }.merge(audatt)
        xml.list(atts) {
          xml.head { sanitize_mixed_content(title, xml, fragments) }  if title

          sn['items'].each do |item|
            xml.item { sanitize_mixed_content(item,xml, fragments)}
          end
        }
      when 'note_definedlist'
        xml.list({:type => 'deflist'}.merge(audatt)) {
          xml.head { sanitize_mixed_content(title,xml, fragments) }  if title

          sn['items'].each do |item|
            xml.defitem {
              xml.label { sanitize_mixed_content(item['label'], xml, fragments) } if item['label']
              xml.item { sanitize_mixed_content(item['value'],xml, fragments )} if item['value']
            }
          end
        }
      end
    end
  end


  def serialize_container(inst, xml, fragments)
    atts = {}

    sub = inst['sub_container']
    top = sub['top_container']['_resolved']

    atts[:id] = prefix_id(SecureRandom.hex)
    last_id = atts[:id]

    atts[:type] = top['type']
    text = top['indicator']

    atts[:label] = I18n.t("enumerations.instance_instance_type.#{inst['instance_type']}",
                          :default => inst['instance_type'])
    atts[:label] << " [#{top['barcode']}]" if top['barcode']

    if (cp = top['container_profile'])
      atts[:altrender] = cp['_resolved']['url'] || cp['_resolved']['name']
    end

    xml.container(atts) {
      sanitize_mixed_content(text, xml, fragments)
    }

    (2..3).each do |n|
      atts = {}

      next unless sub["type_#{n}"]

      atts[:id] = prefix_id(SecureRandom.hex)
      atts[:parent] = last_id
      last_id = atts[:id]

      atts[:type] = sub["type_#{n}"]
      text = sub["indicator_#{n}"]

      xml.container(atts) {
        sanitize_mixed_content(text, xml, fragments)
      }
    end
  end

  def is_digital_object_published?(digital_object, file_version = nil)
    if !digital_object['publish']
      return false
    elsif !file_version.nil? and !file_version['publish']
      return false
    else
      return true
    end
  end

  def serialize_digital_object(digital_object, xml, fragments)
    return if digital_object["publish"] === false && !@include_unpublished
    return if digital_object["suppressed"] === true

    # ANW-285: Only serialize file versions that are published, unless include_unpublished flag is set
    file_versions_to_display = digital_object['file_versions'].select {|fv| fv['publish'] == true || @include_unpublished }

    title = digital_object['title']
    date = digital_object['dates'][0] || {}

    atts = digital_object["publish"] === false ? {:audience => 'internal'} : {}

    content = ""
    content << title if title
    content << ": " if date['expression'] || date['begin']
    if date['expression']
      content << date['expression']
    elsif date['begin']
    content << date['begin']
    if date['end'] != date['begin']
        content << "-#{date['end']}"
      end
    end
    atts['xlink:title'] = digital_object['title'] if digital_object['title']


    if file_versions_to_display.empty?
      atts['xlink:type'] = 'simple'
      atts['xlink:href'] = digital_object['digital_object_id']
      atts['xlink:actuate'] = 'onRequest'
      atts['xlink:show'] = 'new'
      atts['audience'] = 'internal' unless is_digital_object_published?(digital_object)
      xml.dao(atts) {
        xml.daodesc{ sanitize_mixed_content(content, xml, fragments, true) } if content
      }
    elsif file_versions_to_display.length == 1
      file_version = file_versions_to_display.first

      atts['xlink:type'] = 'simple'
      atts['xlink:actuate'] = file_version['xlink_actuate_attribute'] || 'onRequest'
      atts['xlink:show'] = file_version['xlink_show_attribute'] || 'new'
      atts['xlink:role'] = file_version['use_statement'] if file_version['use_statement']
      atts['xlink:href'] = file_version['file_uri']
      atts['audience'] = 'internal' unless is_digital_object_published?(digital_object, file_version)
      xml.dao(atts) {
        xml.daodesc{ sanitize_mixed_content(content, xml, fragments, true) } if content
      }
    else
      xml.daogrp( atts.merge( { 'xlink:type' => 'extended'} ) ) {
        xml.daodesc{ sanitize_mixed_content(content, xml, fragments, true) } if content
        file_versions_to_display.each do |file_version|
          atts['xlink:type'] = 'locator'
          atts['xlink:href'] = file_version['file_uri']
          atts['xlink:role'] = file_version['use_statement'] if file_version['use_statement']
          atts['xlink:title'] = file_version['caption'] if file_version['caption']
          atts['audience'] = 'internal' unless is_digital_object_published?(digital_object, file_version)
          xml.daoloc(atts)
        end
      }
    end
  end


  def serialize_extents(obj, xml, fragments)
    if obj.extents.length
      obj.extents.each do |e|
        next if e["publish"] === false && !@include_unpublished
				audatt = e["publish"] === false ? {:audience => 'internal'} : {}
				# added
				audatt = audatt.merge({:label => 'Physical Description'})

        xml.physdesc({:altrender => e['portion']}.merge(audatt)) {
					# added
#        	xml.extent {
						if e['number'] && e['extent_type']

							# added
							attrs = {:altrender => 'materialtype spaceoccupied'}
							attrs = attrs.merge({:encodinganalog => '300$a'})

							# modified
							#xml.extent({:altrender => 'materialtype spaceoccupied'}) {
							xml.extent( attrs ) {
								sanitize_mixed_content("#{e['number']} #{I18n.t('enumerations.extent_extent_type.'+e['extent_type'], :default => e['extent_type'])}", xml, fragments)
							}
						end
						if e['container_summary']
							xml.extent({:altrender => 'carrier'}) {
								sanitize_mixed_content( e['container_summary'], xml, fragments)
							}
						end
						xml.physfacet { sanitize_mixed_content(e['physical_details'],xml, fragments) } if e['physical_details']
						xml.dimensions  {   sanitize_mixed_content(e['dimensions'],xml, fragments) }  if e['dimensions']
#					}
				}
      end
    end
  end


  def serialize_dates(obj, xml, fragments)
    obj.archdesc_dates.each do |node_data|
      next if node_data["publish"] === false && !@include_unpublished
      audatt = node_data["publish"] === false ? {:audience => 'internal'} : {}
        # added
        encodinganalog = {:encodinganalog=>'245$g'}
        attributes = {}
        attributes = attributes.merge(audatt);
        attributes = attributes.merge(encodinganalog);

			# modified
			#xml.unitdate(node_data[:atts].merge(audatt)){
			xml.unitdate(node_data[:atts].merge(attributes)){
        sanitize_mixed_content( node_data[:content],xml, fragments )
      }
    end
  end

  def serialize_did_notes(data, xml, fragments)
    data.notes.each do |note|
      next if note["publish"] === false && !@include_unpublished
      next unless data.did_note_types.include?(note['type'])

      audatt = note["publish"] === false ? {:audience => 'internal'} : {}
      content = ASpaceExport::Utils.extract_note_text(note, @include_unpublished)

      att = { :id => prefix_id(note['persistent_id']) }.reject {|k,v| v.nil? || v.empty? || v == "null" }
      att ||= {}

      case note['type']
      when 'dimensions', 'physfacet'
        att[:label] = note['label'] if note['label']
        xml.physdesc(audatt) {
          xml.send(note['type'], att) {
            sanitize_mixed_content( content, xml, fragments, ASpaceExport::Utils.include_p?(note['type'])  )
          }
        }
      when 'physdesc'
        att[:label] = note['label'] if note['label']
        xml.send(note['type'], att.merge(audatt)) {
          sanitize_mixed_content(content, xml, fragments,ASpaceExport::Utils.include_p?(note['type']))
        }
      else
        xml.send(note['type'], att.merge(audatt)) {
          sanitize_mixed_content(content, xml, fragments,ASpaceExport::Utils.include_p?(note['type']))
        }
      end
    end
  end

  def serialize_languages(languages, xml, fragments)
    lm = []
    language_notes = languages.map {|l| l['notes']}.compact.reject {|e|  e == [] }.flatten
    if !language_notes.empty?
      language_notes.each do |note|
        unless note["publish"] === false && !@include_unpublished
          audatt = note["publish"] === false ? {:audience => 'internal'} : {}
          content = ASpaceExport::Utils.extract_note_text(note, @include_unpublished)

          att = { :id => prefix_id(note['persistent_id']) }.reject {|k,v| v.nil? || v.empty? || v == "null" }
          att ||= {}

          xml.send(note['type'], att.merge(audatt)) {
            sanitize_mixed_content(content, xml, fragments, ASpaceExport::Utils.include_p?(note['type']))
          }
          lm << note
        end
      end
      if lm == []
        languages = languages.map{|l| l['language_and_script']}.compact
        xml.langmaterial {
          languages.map {|language|
            punctuation = language.equal?(languages.last) ? '.' : ', '
            lang_translation = I18n.t("enumerations.language_iso639_2.#{language['language']}", :default => language['language'])
            if language['script']
              xml.language(:langcode => language['language'], :scriptcode => language['script']) {
                xml.text(lang_translation)
              }
            else
              xml.language(:langcode => language['language']) {
                xml.text(lang_translation)
              }
            end
            xml.text(punctuation)
          }
        }
      end
      # ANW-697: If no Language Text subrecords are available, the Language field translation values for each Language and Script subrecord should be exported, separated by commas, enclosed in <language> elements with associated @langcode and @scriptcode attribute values, and terminated by a period.
    else
      languages = languages.map{|l| l['language_and_script']}.compact
      if !languages.empty?
        xml.langmaterial {
          languages.map {|language|
            punctuation = language.equal?(languages.last) ? '.' : ', '
            lang_translation = I18n.t("enumerations.language_iso639_2.#{language['language']}", :default => language['language'])
            if language['script']
              xml.language(:langcode => language['language'], :scriptcode => language['script']) {
                xml.text(lang_translation)
              }
            else
              xml.language(:langcode => language['language']) {
                xml.text(lang_translation)
              }
            end
            xml.text(punctuation)
          }
        }
      end
    end
  end

  def serialize_note_content(note, xml, fragments)
    return if note["publish"] === false && !@include_unpublished
    audatt = note["publish"] === false ? {:audience => 'internal'} : {}
    content = note["content"]

    atts = {:id => prefix_id(note['persistent_id']) }.reject{|k,v| v.nil? || v.empty? || v == "null" }.merge(audatt)

		# added
		if note['type'] == 'bioghist'
			atts[:encodinganalog] = '545$a'
		elsif note['type'] == 'custodhist'
			atts[:encodinganalog] = '561$a'
		elsif note['type'] == 'acqinfo'
			atts[:encodinganalog] = '541$a'
		elsif note['type'] == 'scopecontent'
			atts[:encodinganalog] = '520$a'
		elsif note['type'] == 'arrangement'
			atts[:encodinganalog] = '351$b'
		elsif note['type'] == 'processinfo'
			atts[:encodinganalog] = '583$a'
		elsif note['type'] == 'accessrestrict'
			atts[:encodinganalog] = '506$a'
		elsif note['type'] == 'userestrict'
			atts[:encodinganalog] = '540$a'
		elsif note['type'] == 'prefercite'
			atts[:encodinganalog] = '524$a'
		elsif note['type'] == 'relatedmaterial'
			atts[:encodinganalog] = '544$a'
		elsif note['type'] == 'separatedmaterial'
			atts[:encodinganalog] = '544$d'
		elsif note['type'] == 'originalsloc'
			atts[:encodinganalog] = '535$a'
		elsif note['type'] == 'altformavail'
			atts[:encodinganalog] = '530$a'
		end

    head_text = note['label'] ? note['label'] : I18n.t("enumerations._note_types.#{note['type']}", :default => note['type'])
    content, head_text = extract_head_text(content, head_text)
    xml.send(note['type'], atts) {
      xml.head { sanitize_mixed_content(head_text, xml, fragments) } unless ASpaceExport::Utils.headless_note?(note['type'], content )
      sanitize_mixed_content(content, xml, fragments, ASpaceExport::Utils.include_p?(note['type']) ) if content
      if note['subnotes']
        serialize_subnotes(note['subnotes'], xml, fragments, ASpaceExport::Utils.include_p?(note['type']))
      end
    }
  end


  def serialize_nondid_notes(data, xml, fragments)
    data.notes.each do |note|
      next if note["publish"] === false && !@include_unpublished
      next if note['internal']
      next if note['type'].nil?
      next unless data.archdesc_note_types.include?(note['type'])
      audatt = note["publish"] === false ? {:audience => 'internal'} : {}
      if note['type'] == 'legalstatus'
        xml.accessrestrict(audatt) {
          serialize_note_content(note, xml, fragments)
        }
      else
        serialize_note_content(note, xml, fragments)
      end
    end
  end


  def serialize_bibliographies(data, xml, fragments)
    data.bibliographies.each do |note|
      next if note["publish"] === false && !@include_unpublished
      content = ASpaceExport::Utils.extract_note_text(note, @include_unpublished)
      note_type = note["type"] ? note["type"] : "bibliography"
      head_text = note['label'] ? note['label'] : I18n.t("enumerations._note_types.#{note_type}", :default => note_type )
      audatt = note["publish"] === false ? {:audience => 'internal'} : {}

      atts = {:id => prefix_id(note['persistent_id']) }.reject{|k,v| v.nil? || v.empty? || v == "null" }.merge(audatt)

      xml.bibliography(atts) {
        xml.head { sanitize_mixed_content(head_text, xml, fragments) }
        sanitize_mixed_content( content, xml, fragments, true)
        note['items'].each do |item|
          xml.bibref { sanitize_mixed_content( item, xml, fragments) }  unless item.empty?
        end
      }
    end
  end


  def serialize_indexes(data, xml, fragments)
    data.indexes.each do |note|
      next if note["publish"] === false && !@include_unpublished
      audatt = note["publish"] === false ? {:audience => 'internal'} : {}
      content = ASpaceExport::Utils.extract_note_text(note, @include_unpublished)
      head_text = nil
      if note['label']
        head_text = note['label']
      elsif note['type']
        head_text = I18n.t("enumerations._note_types.#{note['type']}", :default => note['type'])
      end
      atts = {:id => prefix_id(note["persistent_id"]) }.reject{|k,v| v.nil? || v.empty? || v == "null" }.merge(audatt)

      content, head_text = extract_head_text(content, head_text)
      xml.index(atts) {
        xml.head { sanitize_mixed_content(head_text,xml,fragments ) } unless head_text.nil?
        sanitize_mixed_content(content, xml, fragments, true)
        note['items'].each do |item|
          next unless (node_name = data.index_item_type_map[item['type']])
          xml.indexentry {
            atts = item['reference'] ? {:target => prefix_id( item['reference']) } : {}
            if (val = item['value'])
              xml.send(node_name) {  sanitize_mixed_content(val, xml, fragments )}
            end
            if (val = item['reference_text'])
              xml.ref(atts) {
                sanitize_mixed_content( val, xml, fragments)
              }
            end
          }
        end
      }
    end
  end


  def serialize_eadheader(data, xml, fragments)

    ark_url = AppConfig[:arks_enabled] ? ArkName::get_ark_url(data.id, :resource) : nil

    eadid_url = ark_url.nil? ? data.ead_location : ark_url

    eadheader_atts = {:findaidstatus => data.finding_aid_status,
                      :repositoryencoding => "iso15511",
                      :countryencoding => "iso3166-1",
                      :dateencoding => "iso8601",
                      :langencoding => "iso639-2b"}.reject{|k,v| v.nil? || v.empty? || v == "null"}

    xml.eadheader(eadheader_atts) {

      eadid_atts = {:countrycode => data.repo.country,
              :url => eadid_url,
              :identifier => data.ead_id, # added
              :mainagencycode => data.mainagencycode}.reject{|k,v| v.nil? || v.empty? || v == "null" }

      xml.eadid(eadid_atts) {
        xml.text data.ead_id
      }

      xml.filedesc {

        xml.titlestmt {

          titleproper = ""
          titleproper += "#{data.finding_aid_title} " if data.finding_aid_title
          titleproper += "#{data.title}" if ( data.title && titleproper.empty? )
          titleproper += "<num>#{(0..3).map{|i| data.send("id_#{i}")}.compact.join('.')}</num>"
          xml.titleproper("type" => "filing") { sanitize_mixed_content(data.finding_aid_filing_title, xml, fragments)} unless data.finding_aid_filing_title.nil?
          xml.titleproper {  sanitize_mixed_content(titleproper, xml, fragments) }
          xml.subtitle {  sanitize_mixed_content(data.finding_aid_subtitle, xml, fragments) } unless data.finding_aid_subtitle.nil?
          xml.author { sanitize_mixed_content(data.finding_aid_author, xml, fragments) }  unless data.finding_aid_author.nil?
          xml.sponsor { sanitize_mixed_content( data.finding_aid_sponsor, xml, fragments) } unless data.finding_aid_sponsor.nil?

        }

        unless data.finding_aid_edition_statement.nil?
          xml.editionstmt {
            sanitize_mixed_content(data.finding_aid_edition_statement, xml, fragments, true )
          }
        end

        xml.publicationstmt {
          xml.publisher { sanitize_mixed_content(data.repo.name,xml, fragments) }

          if data.repo.image_url
            xml.p ( { "id" => "logostmt" } ) {
              xml.extref ({"xlink:href" => data.repo.image_url,
                          "xlink:actuate" => "onLoad",
                          "xlink:show" => "embed",
                          "xlink:type" => "simple"
                          })
                          }
          end
          if (data.finding_aid_date)
            xml.p {
                  val = data.finding_aid_date
                  xml.date {   sanitize_mixed_content( val, xml, fragments) }
                  }
          end

          unless data.addresslines.empty?
            xml.address {
              data.addresslines.each do |line|
                xml.addressline { sanitize_mixed_content( line, xml, fragments) }
              end
              if data.repo.url
                xml.addressline ( "URL: " ) {
                  xml.extptr ( {
                          "xlink:href" => data.repo.url,
                          "xlink:title" => data.repo.url,
                          "xlink:type" => "simple",
                          "xlink:show" => "new"
                          } )
                 }
              end
            }
          end
        }

        if (data.finding_aid_series_statement)
          val = data.finding_aid_series_statement
          xml.seriesstmt {
            sanitize_mixed_content(  val, xml, fragments, true )
          }
        end
        if ( data.finding_aid_note )
            val = data.finding_aid_note
            xml.notestmt { xml.note { sanitize_mixed_content(  val, xml, fragments, true )} }
        end

      }

      xml.profiledesc {
        creation = "This finding aid was produced using ArchivesSpace on <date>#{Time.now}</date>."
        xml.creation {  sanitize_mixed_content( creation, xml, fragments) }

        if (val = data.finding_aid_language_note)
          xml.langusage (fragments << val)
        else
          xml.langusage() {
            xml.text(I18n.t("resource.finding_aid_langusage_label"))
            xml.language({langcode: "#{data.finding_aid_language}", :scriptcode => "#{data.finding_aid_script}"}) {
              xml.text(I18n.t("enumerations.language_iso639_2.#{data.finding_aid_language}"))
              xml.text(", ")
              xml.text(I18n.t("enumerations.script_iso15924.#{data.finding_aid_script}"))
              xml.text(" #{I18n.t("language_and_script.script").downcase}")}
          xml.text(".")
					}
        end

        if (val = data.descrules)
          xml.descrules { sanitize_mixed_content(val, xml, fragments) }
        end
      }

      export_rs = @include_unpublished ? data.revision_statements : data.revision_statements.reject { |rs| !rs['publish'] }
      if export_rs.length > 0
        xml.revisiondesc {
          export_rs.each do |rs|
            if rs['description'] && rs['description'].strip.start_with?('<')
              xml.text (fragments << rs['description'] )
            else
              xml.change(rs['publish'] ? nil : {:audience => 'internal'}) {
                rev_date = rs['date'] ? rs['date'] : ""
                xml.date (fragments <<  rev_date )
                xml.item (fragments << rs['description']) if rs['description']
              }
            end
          end
        }
      end
    }
  end
end