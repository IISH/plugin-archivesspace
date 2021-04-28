# Extens wordt nu extent_number en extent_type
# locations_location en location_container

class CustomAccessionsReport < AbstractReport
  register_report(params: [['template', CustomReportTemplate,  'Template.']])

  MAX_EXTENTS = 4 # five columns

  def fix_row(row)
    clean_row(row)
    add_sub_reports(row)
  end

  def query
    results = db.fetch(query_string)
    info[:number_of_accessions] = results.count
    results
  end

  def query_string
    "select
      id as accession_id,
      identifier as accession_number,
      title as record_title,
      accession_date as accession_date,
      provenance as provenance,
      extent_number,
      extent_type,
      general_note,
      container_summary,
      date_expression,
      acquisition_type_id as acquisition_type,
      content_description as description_note,
      condition_description as condition_note,
      inventory,
      access_restrictions,
      access_restrictions_note,
      use_restrictions_note
    from accession natural left outer join

      (select
        accession_id as id,
        GROUP_CONCAT(number SEPARATOR ', ') as extent_number,
        GROUP_CONCAT(extent_type_id SEPARATOR ', ') as extent_type,
        GROUP_CONCAT(extent.container_summary SEPARATOR ', ') as container_summary
      from extent
      group by accession_id) as extent_cnt

      natural left outer join
      (select
        accession_id as id,
        group_concat(distinct expression separator ', ') as date_expression,
        group_concat(distinct begin separator ', ') as begin_date,
        group_concat(distinct end separator ', ') as end_date
      from date, enumeration_value
      where date.date_type_id = enumeration_value.id and enumeration_value.value = 'inclusive'
      group by accession_id) as inclusive_date

      natural left outer join
      (select
        accession_id as id,
        group_concat(distinct begin separator ', ') as bulk_begin_date,
        group_concat(distinct end separator ', ') as bulk_end_date
        from date, enumeration_value
        where date.date_type_id = enumeration_value.id and enumeration_value.value = 'bulk'
        group by accession_id) as bulk_date

      natural left outer join
      (select
        accession_id as id,
        count(*) != 0 as rights_transferred,
        group_concat(outcome_note separator ', ') as rights_transferred_note
      from event_link_rlshp, event, enumeration_value
      where event_link_rlshp.event_id = event.id
        and event.event_type_id = enumeration_value.id and enumeration_value.value = 'copyright_transfer'
      group by event_link_rlshp.accession_id) as rights_transferred

      natural left outer join
      (select
        accession_id as id,
        count(*) != 0 as acknowledgement_sent
      from event_link_rlshp, event, enumeration_value
      where event_link_rlshp.event_id = event.id
        and event.event_type_id = enumeration_value.id and enumeration_value.value = 'acknowledgement_sent'
      group by event_link_rlshp.accession_id) as acknowledgement_sent
    where accession.repo_id = #{db.literal(@repo_id)}"
  end

  def clean_row(row)
    ReportUtils.fix_identifier_format(row, :accession_number)
    ReportUtils.get_enum_values(row, [:acquisition_type])
    self.fix_extent_format(row)
    ReportUtils.fix_boolean_fields(row, %i[restrictions_apply
                                           access_restrictions use_restrictions
                                           rights_transferred
                                           acknowledgement_sent])
  end

  def add_sub_reports(row)
    row.delete(:accession_id)
  end

  def identifier_field
    :accession_number
  end

  def fix_extent_format(row)

    extents = 0
    row[:extent_number] = 0.0 unless row[:extent_number]
    extent_types = row[:extent_type].split(', ')
    extent_numbers = row[:extent_number].split(', ')

    extent_types.each_with_index do |value, index|
        begin
          enum_value = EnumerationValue.get_or_die(value)
          enumeration = enum_value.enumeration.name
          extent_type = I18n.t("enumerations.#{enumeration}.#{enum_value.value}", :default => enum_value.value)
          extent_number = extent_numbers[index]
          label_extent_type = "extent_type_#{index}"
          label_extent_number = "extent_number_#{index}"
          row[label_extent_number] = extent_number
          row[label_extent_type] = extent_type
          extents = index + 1
        rescue Exception => e
          row['error'] = "Missing enum value: #{value}"
        end
    end

    (extents..MAX_EXTENTS).each do |index|
      label_extent_type = "extent_type_#{index}"
      label_extent_number = "extent_number_#{index}"
      row[label_extent_number] = 0.0
      row[label_extent_type] = ''
    end

    row.delete(:extent_type)
    row.delete(:extent_number)
  end

end
