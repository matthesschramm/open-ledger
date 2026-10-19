// Invoice PDF generation using @react-pdf/renderer
import React from 'react'
import { Document, Page, Text, View, StyleSheet, pdf } from '@react-pdf/renderer'
import { formatCurrency } from './money'
import { formatDate } from './format-date'

// Define styles for the PDF
const styles = StyleSheet.create({
  page: {
    padding: 40,
    fontSize: 10,
    fontFamily: 'Helvetica',
  },
  header: {
    marginBottom: 30,
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 20,
  },
  orgBlock: {
    marginBottom: 10,
  },
  orgName: {
    fontSize: 12,
    fontWeight: 'bold',
    marginBottom: 4,
  },
  orgDetail: {
    fontSize: 10,
    marginBottom: 2,
    color: '#333',
  },
  twoColumn: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 30,
  },
  column: {
    width: '48%',
  },
  sectionTitle: {
    fontSize: 10,
    fontWeight: 'bold',
    marginBottom: 6,
    color: '#666',
    textTransform: 'uppercase',
  },
  detailText: {
    fontSize: 10,
    marginBottom: 3,
  },
  table: {
    marginTop: 20,
    marginBottom: 20,
  },
  tableHeader: {
    flexDirection: 'row',
    borderBottomWidth: 1,
    borderBottomColor: '#000',
    paddingBottom: 8,
    marginBottom: 8,
  },
  tableRow: {
    flexDirection: 'row',
    paddingVertical: 6,
    borderBottomWidth: 0.5,
    borderBottomColor: '#ddd',
  },
  col1: {
    width: '50%',
  },
  col2: {
    width: '20%',
    textAlign: 'right',
  },
  col3: {
    width: '30%',
    textAlign: 'right',
  },
  tableHeaderText: {
    fontSize: 10,
    fontWeight: 'bold',
  },
  tableText: {
    fontSize: 10,
  },
  totals: {
    marginLeft: 'auto',
    width: '40%',
    marginTop: 10,
  },
  totalRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 4,
  },
  totalLabel: {
    fontSize: 10,
  },
  totalValue: {
    fontSize: 10,
    textAlign: 'right',
  },
  grandTotalRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 6,
    borderTopWidth: 1,
    borderTopColor: '#000',
    marginTop: 6,
  },
  grandTotalLabel: {
    fontSize: 11,
    fontWeight: 'bold',
  },
  grandTotalValue: {
    fontSize: 11,
    fontWeight: 'bold',
    textAlign: 'right',
  },
  paymentSection: {
    marginTop: 30,
    padding: 12,
    backgroundColor: '#f9f9f9',
    borderWidth: 1,
    borderColor: '#ddd',
  },
  paymentTitle: {
    fontSize: 11,
    fontWeight: 'bold',
    marginBottom: 8,
  },
  paymentText: {
    fontSize: 9,
    lineHeight: 1.4,
    whiteSpace: 'pre-wrap',
  },
})

interface InvoicePDFProps {
  invoice: {
    number: string
    invoice_date: string
    due_date: string | null
    total_cents: number
    received_cents: number
    notes?: string | null
  }
  customer: {
    name: string
    email: string | null
    address?: string | null
  }
  lines: Array<{
    description: string
    quantity?: number
    amount_cents: number
  }>
  organization: {
    legal_name: string
    registration_id?: string | null
    address?: string | null
    email?: string | null
    phone?: string | null
    payment_details?: string | null
  }
}

const InvoicePDF: React.FC<InvoicePDFProps> = ({ invoice, customer, lines, organization }) => {
  const amountDue = invoice.total_cents - invoice.received_cents

  return (
    <Document>
      <Page size="A4" style={styles.page}>
        {/* Header */}
        <View style={styles.header}>
          <Text style={styles.title}>Invoice</Text>
          
          {/* Organization block */}
          <View style={styles.orgBlock}>
            <Text style={styles.orgName}>{organization.legal_name}</Text>
            {organization.registration_id && (
              <Text style={styles.orgDetail}>{organization.registration_id}</Text>
            )}
            {organization.address && (
              <Text style={styles.orgDetail}>{organization.address}</Text>
            )}
            {organization.email && (
              <Text style={styles.orgDetail}>{organization.email}</Text>
            )}
            {organization.phone && (
              <Text style={styles.orgDetail}>{organization.phone}</Text>
            )}
          </View>
        </View>

        {/* Two column section: Bill To and Invoice Details */}
        <View style={styles.twoColumn}>
          <View style={styles.column}>
            <Text style={styles.sectionTitle}>Bill To</Text>
            <Text style={styles.detailText}>{customer.name}</Text>
            {customer.email && <Text style={styles.detailText}>{customer.email}</Text>}
            {customer.address && <Text style={styles.detailText}>{customer.address}</Text>}
          </View>
          
          <View style={styles.column}>
            <Text style={styles.sectionTitle}>Invoice Details</Text>
            <Text style={styles.detailText}>Invoice #: {invoice.number}</Text>
            <Text style={styles.detailText}>Issue Date: {formatDate(invoice.invoice_date)}</Text>
            {invoice.due_date && (
              <Text style={styles.detailText}>Due Date: {formatDate(invoice.due_date)}</Text>
            )}
          </View>
        </View>

        {/* Line items table */}
        <View style={styles.table}>
          <View style={styles.tableHeader}>
            <Text style={[styles.tableHeaderText, styles.col1]}>Description</Text>
            <Text style={[styles.tableHeaderText, styles.col2]}>Qty</Text>
            <Text style={[styles.tableHeaderText, styles.col3]}>Amount</Text>
          </View>
          
          {lines.map((line, index) => (
            <View key={index} style={styles.tableRow}>
              <Text style={[styles.tableText, styles.col1]}>{line.description}</Text>
              <Text style={[styles.tableText, styles.col2]}>{line.quantity || 1}</Text>
              <Text style={[styles.tableText, styles.col3]}>
                {formatCurrency(line.amount_cents)}
              </Text>
            </View>
          ))}
        </View>

        {/* Totals */}
        <View style={styles.totals}>
          <View style={styles.totalRow}>
            <Text style={styles.totalLabel}>Subtotal</Text>
            <Text style={styles.totalValue}>{formatCurrency(invoice.total_cents)}</Text>
          </View>
          
          <View style={styles.grandTotalRow}>
            <Text style={styles.grandTotalLabel}>Total</Text>
            <Text style={styles.grandTotalValue}>{formatCurrency(invoice.total_cents)}</Text>
          </View>
          
          <View style={styles.totalRow}>
            <Text style={styles.grandTotalLabel}>Amount Due</Text>
            <Text style={styles.grandTotalValue}>{formatCurrency(amountDue)}</Text>
          </View>
        </View>

        {/* Payment details section */}
        {organization.payment_details && organization.payment_details.trim() && (
          <View style={styles.paymentSection}>
            <Text style={styles.paymentTitle}>Payment Details</Text>
            <Text style={styles.paymentText}>{organization.payment_details}</Text>
          </View>
        )}
      </Page>
    </Document>
  )
}

export async function generateInvoicePDF(data: InvoicePDFProps): Promise<Buffer> {
  const doc = <InvoicePDF {...data} />
  const asPdf = pdf(doc)
  const blob = await asPdf.toBlob()
  const arrayBuffer = await blob.arrayBuffer()
  return Buffer.from(arrayBuffer)
}

export function getInvoicePDFFilename(invoiceNumber: string): string {
  return `${invoiceNumber}.pdf`
}
