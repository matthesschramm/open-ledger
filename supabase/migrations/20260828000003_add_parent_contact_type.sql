-- Add 'Parent' to contact_type enum for intercompany relationships
alter type contact_type add value if not exists 'Parent';
