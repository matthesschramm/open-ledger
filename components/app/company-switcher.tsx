'use client'

import { useState, useTransition } from 'react'
import { Check, ChevronsUpDown, Plus } from 'lucide-react'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandSeparator,
} from '@/components/ui/command'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from '@/components/ui/popover'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { switchCompany, createCompany } from '@/lib/actions'
import { useRouter } from 'next/navigation'

type Company = {
  id: string
  name: string
  role: string
  isActive: boolean
}

type CompanySwitcherProps = {
  companies: Company[]
  currentCompany: Company | null
}

export function CompanySwitcher({ companies, currentCompany }: CompanySwitcherProps) {
  const router = useRouter()
  const [open, setOpen] = useState(false)
  const [showNewCompanyDialog, setShowNewCompanyDialog] = useState(false)
  const [newCompanyName, setNewCompanyName] = useState('')
  const [isPending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)

  const handleSwitchCompany = async (companyId: string) => {
    startTransition(async () => {
      const result = await switchCompany(companyId)
      if (result.success) {
        setOpen(false)
        router.refresh()
      } else {
        setError(result.error)
      }
    })
  }

  const handleCreateCompany = async (e: React.FormEvent) => {
    e.preventDefault()
    setError(null)
    
    startTransition(async () => {
      try {
        const result = await createCompany(newCompanyName)
        if (result.success) {
          // Switch to the newly created company
          if (result.companyId) {
            const switchResult = await switchCompany(result.companyId)
            if (switchResult.success) {
              setShowNewCompanyDialog(false)
              setNewCompanyName('')
              setError(null)
              router.refresh()
            } else {
              console.error('Switch to new company failed:', switchResult.error)
              setError(switchResult.error || 'Created company but failed to switch to it')
              // Still refresh to show the new company in the list
              router.refresh()
            }
          } else {
            setError('Company created but no ID returned')
            router.refresh()
          }
        } else {
          console.error('Create company failed:', result.error)
          setError(result.error || 'Failed to create company')
        }
      } catch (err) {
        console.error('Create company exception:', err)
        setError(err instanceof Error ? err.message : 'Unexpected error creating company')
      }
    })
  }

  return (
    <>
      <Popover open={open} onOpenChange={setOpen}>
        <PopoverTrigger asChild>
          <Button
            variant="outline"
            role="combobox"
            aria-expanded={open}
            className="w-full justify-between"
            disabled={isPending}
          >
            <span className="truncate">
              {currentCompany?.name || 'Select company'}
            </span>
            <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50" />
          </Button>
        </PopoverTrigger>
        <PopoverContent className="w-[240px] p-0" align="start">
          <Command>
            <CommandInput placeholder="Search companies..." />
            <CommandList>
              <CommandEmpty>No companies found.</CommandEmpty>
              <CommandGroup heading="Your companies">
                {companies.map((company) => (
                  <CommandItem
                    key={company.id}
                    value={company.name}
                    onSelect={() => handleSwitchCompany(company.id)}
                    disabled={isPending}
                  >
                    <Check
                      className={cn(
                        'mr-2 h-4 w-4',
                        company.isActive ? 'opacity-100' : 'opacity-0'
                      )}
                    />
                    <div className="flex-1 truncate">{company.name}</div>
                  </CommandItem>
                ))}
              </CommandGroup>
              <CommandSeparator />
              <CommandGroup>
                <CommandItem
                  onSelect={() => {
                    setOpen(false)
                    setShowNewCompanyDialog(true)
                  }}
                  disabled={isPending}
                >
                  <Plus className="mr-2 h-4 w-4" />
                  Create company
                </CommandItem>
              </CommandGroup>
            </CommandList>
          </Command>
        </PopoverContent>
      </Popover>

      <Dialog open={showNewCompanyDialog} onOpenChange={setShowNewCompanyDialog}>
        <DialogContent>
          <form onSubmit={handleCreateCompany}>
            <DialogHeader>
              <DialogTitle>Create company</DialogTitle>
              <DialogDescription>
                Create a new company with empty books. You will be the owner.
              </DialogDescription>
            </DialogHeader>
            <div className="py-4">
              <Label htmlFor="company-name">Company name</Label>
              <Input
                id="company-name"
                value={newCompanyName}
                onChange={(e) => setNewCompanyName(e.target.value)}
                placeholder="Acme Inc."
                disabled={isPending}
                required
                className="mt-2"
              />
              {error && (
                <p className="mt-2 text-sm text-destructive">{error}</p>
              )}
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={() => {
                  setShowNewCompanyDialog(false)
                  setNewCompanyName('')
                  setError(null)
                }}
                disabled={isPending}
              >
                Cancel
              </Button>
              <Button type="submit" disabled={isPending || !newCompanyName.trim()}>
                {isPending ? 'Creating...' : 'Create company'}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </>
  )
}
